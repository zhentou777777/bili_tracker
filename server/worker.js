/**
 * 极轻量服务端：Cloudflare Worker
 *
 * 只做三件事，且刻意不做第四件：
 *   1. GET  /rules  下发平台接口规则（接口改了改 JSON，不用发版）
 *   2. POST /push   推送中继：收到摘要转发 FCM / APNs，转发完即忘
 *   3. scheduled    开播兜底：低频轮询 B 站公开直播接口（不需要 Cookie）
 *
 * 绝对不做：不接收 Cookie、不代理任何需要登录的平台接口、不落库。
 * 所有日志只记状态码与平台名，不记推送内容。
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // CORS：客户端可能从任意网络环境调用
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    if (url.pathname === '/rules') return handleRules(request, env);
    if (url.pathname === '/push' && request.method === 'POST') {
      return handlePush(request, env);
    }
    if (url.pathname === '/health') {
      return json({ ok: true, ts: Date.now() });
    }

    return json({ error: 'not found' }, 404);
  },

  /**
   * Cron 兜底：App 被系统杀掉时，靠这里补上开播提醒。
   * 只轮询公开接口（不需要任何 Cookie），不碰用户数据。
   */
  async scheduled(event, env, ctx) {
    const uids = await loadWatchUids(env);
    if (!uids.length) return;

    const live = await fetchBiliLiveStatus(uids);
    const started = await diffAgainstCache(env, live);

    for (const s of started) {
      const tokens = await loadTokensForUid(env, s.uid);
      for (const t of tokens) {
        await deliver(env, t, {
          title: `🔴 ${s.uname} 开播了`,
          body: s.title || '点击前往直播间',
          data: { type: 'live', uid: String(s.uid), room: String(s.room_id) },
        });
      }
    }
  },
};

// ---------------------------------------------------------------- 规则下发

async function handleRules(request, env) {
  let body = null;

  if (env.RULES_KV) {
    body = await env.RULES_KV.get('platforms.json');
  }
  if (!body && env.RULES_JSON) {
    body = env.RULES_JSON;
  }
  if (!body) {
    return json({ error: '规则未配置：请设置 RULES_KV 或 RULES_JSON' }, 503);
  }

  return new Response(body, {
    headers: {
      ...corsHeaders(),
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    },
  });
}

// ---------------------------------------------------------------- 推送中继

async function handlePush(request, env) {
  // 共享密钥，避免中继被蹭用刷推送
  if (env.PUSH_SECRET) {
    const given = request.headers.get('X-Push-Secret');
    if (given !== env.PUSH_SECRET) {
      return json({ error: 'unauthorized' }, 401);
    }
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return json({ error: 'bad json' }, 400);
  }

  const { token, platform, title, body, data } = payload || {};
  if (!token || typeof token !== 'string') {
    return json({ error: 'missing token' }, 400);
  }

  // 只保留摘要字段，杜绝把完整动态内容或 Cookie 带进来
  const safe = {
    title: String(title || '').slice(0, 100),
    body: String(body || '').slice(0, 200),
    data: sanitizeData(data),
  };

  try {
    const result =
      platform === 'ios' || platform === 'apns'
        ? await pushApns(env, token, safe)
        : await pushFcm(env, token, safe);

    // 日志只记结果，不记内容
    console.log(`push ok platform=${platform} status=${result.status}`);
    return json({ ok: true });
  } catch (e) {
    console.log(`push fail platform=${platform} err=${e.message}`);
    return json({ error: 'push failed' }, 502);
  }
}

function sanitizeData(data) {
  if (!data || typeof data !== 'object') return {};
  const out = {};
  const allow = ['type', 'uid', 'room', 'url', 'kind', 'ts'];
  for (const k of Object.keys(data)) {
    if (allow.includes(k)) {
      out[k] = String(data[k]).slice(0, 200);
    }
  }
  return out;
}

// ---------------------------------------------------------------- FCM

async function pushFcm(env, token, safe) {
  const accessToken = await getFcmAccessToken(env);
  const project = env.FCM_PROJECT_ID;
  if (!project) throw new Error('FCM_PROJECT_ID 未配置');

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${project}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: safe.title, body: safe.body },
          data: safe.data,
          android: { priority: 'HIGH' },
          apns: { payload: { aps: { sound: 'default' } } },
        },
      }),
    }
  );
  if (!res.ok) throw new Error(`fcm ${res.status}`);
  return res;
}

let cachedFcmToken = null;
let cachedFcmExp = 0;

async function getFcmAccessToken(env) {
  if (cachedFcmToken && Date.now() < cachedFcmExp) return cachedFcmToken;

  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT);
  const now = Math.floor(Date.now() / 1000);
  const jwt = await signRs256(
    {
      iss: sa.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    },
    sa.private_key
  );

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  const json_ = await res.json();
  if (!json_.access_token) throw new Error('fcm token 获取失败');

  cachedFcmToken = json_.access_token;
  cachedFcmExp = Date.now() + (json_.expires_in - 120) * 1000;
  return cachedFcmToken;
}

// ---------------------------------------------------------------- APNs

let cachedApnsToken = null;
let cachedApnsExp = 0;

async function pushApns(env, token, safe) {
  const jwt = await getApnsToken(env);
  const host = env.APNS_SANDBOX === 'true'
    ? 'api.sandbox.push.apple.com'
    : 'api.push.apple.com';

  const res = await fetch(`https://${host}/3/device/${token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': env.APNS_BUNDLE_ID,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      aps: { alert: { title: safe.title, body: safe.body }, sound: 'default' },
      ...safe.data,
    }),
  });
  if (!res.ok) throw new Error(`apns ${res.status}`);
  return res;
}

async function getApnsToken(env) {
  if (cachedApnsToken && Date.now() < cachedApnsExp) return cachedApnsToken;
  const now = Math.floor(Date.now() / 1000);
  const jwt = await signEs256(
    { iss: env.APNS_TEAM_ID, iat: now, exp: now + 3000 },
    env.APNS_AUTH_KEY,
    env.APNS_KEY_ID
  );
  cachedApnsToken = jwt;
  cachedApnsExp = Date.now() + 2700 * 1000;
  return jwt;
}

// ---------------------------------------------------------------- 签名工具

function b64url(bytes) {
  let s = '';
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function pemToDer(pem, label) {
  const b64 = pem
    .replace(`-----BEGIN ${label}-----`, '')
    .replace(`-----END ${label}-----`, '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function signRs256(claim, privateKeyPem) {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(privateKeyPem, 'PRIVATE KEY'),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const payload = b64url(new TextEncoder().encode(JSON.stringify(claim)));
  const data = new TextEncoder().encode(`${header}.${payload}`);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, data);
  return `${header}.${payload}.${b64url(sig)}`;
}

async function signEs256(claim, p8Key, keyId) {
  const der = pemToDer(p8Key, 'PRIVATE KEY');
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  );
  const header = b64url(
    new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))
  );
  const payload = b64url(new TextEncoder().encode(JSON.stringify(claim)));
  const data = new TextEncoder().encode(`${header}.${payload}`);
  const sig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    data
  );
  return `${header}.${payload}.${b64url(sig)}`;
}

// ---------------------------------------------------------------- 开播兜底

/**
 * B 站直播状态是公开接口，实测无需 Cookie —— 这是服务端唯一允许碰的平台请求。
 * 正因为它不需要任何凭据，才不违反「服务端不代理用户请求」的原则。
 */
async function fetchBiliLiveStatus(uids) {
  const params = uids.map((u) => `uids[]=${encodeURIComponent(u)}`).join('&');
  const res = await fetch(
    `https://api.live.bilibili.com/room/v1/Room/get_status_info_by_uids?${params}`,
    {
      headers: {
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          + '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        Referer: 'https://live.bilibili.com/',
      },
    }
  );
  if (!res.ok) return [];
  const json_ = await res.json();
  if (json_.code !== 0 || !json_.data) return [];

  return Object.values(json_.data)
    .filter((d) => d && d.live_status === 1)
    .map((d) => ({
      uid: d.uid,
      uname: d.uname,
      room_id: d.room_id,
      title: d.title,
      live_time: d.live_time,
    }));
}

async function diffAgainstCache(env, live) {
  if (!env.LIVE_KV || !live.length) return live;
  const started = [];
  for (const s of live) {
    const key = `live:${s.uid}:${s.room_id}:${s.live_time}`;
    const seen = await env.LIVE_KV.get(key);
    if (!seen) {
      await env.LIVE_KV.put(key, '1', { expirationTtl: 60 * 60 * 12 });
      started.push(s);
    }
  }
  return started;
}

// ---------------------------------------------------------------- 存储读取

async function loadWatchUids(env) {
  if (!env.WATCH_KV) return [];
  const raw = await env.WATCH_KV.get('watch_uids');
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.slice(0, 200) : [];
  } catch {
    return [];
  }
}

async function loadTokensForUid(env, uid) {
  if (!env.WATCH_KV) return [];
  const raw = await env.WATCH_KV.get(`tokens:${uid}`);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.slice(0, 500) : [];
  } catch {
    return [];
  }
}

async function deliver(env, token, safe) {
  const platform = token.length > 100 ? 'ios' : 'android';
  return platform === 'ios'
    ? pushApns(env, token, safe)
    : pushFcm(env, token, safe);
}

// ---------------------------------------------------------------- 工具

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders(), 'Content-Type': 'application/json' },
  });
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Push-Secret',
  };
}
