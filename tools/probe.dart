/// CLI 探针：脱离 App，直接打真实 B 站接口，验证核心链路。
///
/// 用途：
///   dart tools/probe.dart                    # 跑公开可验证的部分
///   BILI_COOKIE='SESSDATA=..; bili_jct=..; DedeUserID=..' dart tools/probe.dart
///
/// 不带 Cookie 时，需要登录的接口会返回 -101，这本身就是「Cookie 失效检测」的验证。
library probe;

// 本文件是命令行探针（用 dart tools/probe.dart 直接跑），不是打进 App 的
// 生产代码，因此下面两类 lint 在此处不适用，整文件豁免并说明原因：
//   avoid_print                    —— 探针的全部输出就是靠 print 打到终端
//   avoid_relative_lib_imports     —— 故意用相对路径 import lib/ 下的源码，
//                                     这样不依赖 package:bili_tracker 解析，
//                                     任何装了 Dart SDK 的机器都能直接跑
// ignore_for_file: avoid_print, avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import '../lib/core/http.dart';
import '../lib/core/md5.dart';
import '../lib/core/rules.dart';
import '../lib/core/wbi.dart';
import '../lib/platform/bilibili.dart';
import '../lib/platform/models.dart';

/// dart:io 版请求器，探针专用。
class IoHttpSender implements HttpSender {
  @override
  Future<HttpResp> get(String url, {Map<String, String>? headers}) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      headers?.forEach((String k, String v) => req.headers.set(k, v));
      final HttpClientResponse resp = await req.close();
      final String body = await resp.transform(utf8.decoder).join();
      return HttpResp(status: resp.statusCode, body: body);
    } finally {
      client.close();
    }
  }
}

int _passed = 0;
int _failed = 0;

void ok(String name, String detail) {
  _passed++;
  print('  ✅ $name${detail.isEmpty ? '' : '  $detail'}');
}

void warn(String name, String detail) {
  print('  ⚠️  $name  $detail');
}

void fail(String name, String detail) {
  _failed++;
  print('  ❌ $name  $detail');
}

Future<void> main(List<String> args) async {
  final String cookie = Platform.environment['BILI_COOKIE'] ?? '';
  print('═' * 64);
  print(' B 站链路探针');
  print(' Cookie: ${cookie.isEmpty ? '未提供（仅验证公开链路）' : '已提供 ${cookie.split(';').length} 个字段'}');
  print('═' * 64);

  // 1. MD5 自检（RFC 1321 测试向量）
  print('\n[1] MD5 实现自检');
  _checkMd5('', 'd41d8cd98f00b204e9800998ecf8427e');
  _checkMd5('abc', '900150983cd24fb0d6963f7d28e17f72');
  _checkMd5('message digest', 'f96b697d7cb7938d525a2f31aaf161d0');
  _checkMd5('abcdefghijklmnopqrstuvwxyz', 'c3fcd3d76192e4007dfb496cca67e13b');
  _checkMd5('中文测试!@#', '568279495d2cea5cc71b8688b19a9d3a');

  // 2. 表单编码（必须与 Python quote_plus 一致，否则 w_rid 必错）
  print('\n[2] 表单编码对齐 Python quote_plus');
  _checkEq('空格', formEncode('a b'), 'a+b');
  _checkEq('中文', formEncode('中文'), '%E4%B8%AD%E6%96%87');
  _checkEq('保留字符', formEncode("a!b'c(d)e*f"), 'a%21b%27c%28d%29e%2Af');
  _checkEq('unreserved', formEncode('a-b_c.d~e'), 'a-b_c.d~e');

  // 3. 规则文件加载
  print('\n[3] 规则文件加载');
  final File ruleFile = File('assets/rules/platforms.json');
  if (!ruleFile.existsSync()) {
    fail('规则文件', 'assets/rules/platforms.json 不存在');
    return;
  }
  RuleSet rules;
  try {
    rules = RuleSet.fromJsonString(ruleFile.readAsStringSync());
    ok('规则解析', 'version=${rules.version} 平台=${rules.platforms.map((PlatformRule p) => p.id).join(',')}');
    final PlatformRule? bili = rules.platform('bilibili');
    if (bili == null) {
      fail('B站规则', '未找到 bilibili 平台定义');
      return;
    }
    ok('端点数量', '${bili.endpoints.length} 个：${bili.endpoints.keys.join(', ')}');
  } catch (e) {
    fail('规则解析', '$e');
    return;
  }

  final PlatformRule biliRule = rules.platform('bilibili')!;
  final IoHttpSender sender = IoHttpSender();

  // 4. WBI 密钥
  print('\n[4] WBI 密钥获取');
  final WbiKeyCache cache = WbiKeyCache(() async => null);
  final BilibiliAdapter probeAdapter = BilibiliAdapter(
    rule: biliRule,
    sender: sender,
    cookies: () async => cookie,
    signer: WbiSigner(cache),
  );

  String? mixinKey;
  try {
    final Map<String, dynamic>? nav = await probeAdapter.nav();
    mixinKey = WbiKeyCache.deriveMixinKey(nav);
    if (mixinKey != null) {
      cache.seed(mixinKey);
      ok('mixin_key', '$mixinKey（长度 ${mixinKey.length}）');
    } else {
      fail('mixin_key', 'nav 未返回 wbi_img');
    }
  } catch (e) {
    fail('nav 请求', '$e');
  }

  // 5. 签名串生成
  if (mixinKey != null) {
    print('\n[5] WBI 签名串');
    final WbiSigner signer = WbiSigner(cache);
    final String? q = await signer.signQuery(
      <String, Object>{'mid': 2, 'pn': 1, 'ps': 30, 'platform': 'web'},
      now: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );
    if (q != null) {
      ok('签名输出', q);
      if (q.contains('w_rid=') && q.contains('wts=')) {
        ok('签名要素', 'wts + w_rid 均已注入');
      } else {
        fail('签名要素', '缺少 wts 或 w_rid');
      }
      // 与 Python 独立实现比对
      final String? py = await _pythonCrossCheck(mixinKey);
      if (py != null) {
        final String pyRid = py.split('w_rid=').last;
        final String dartRid = q.split('w_rid=').last;
        if (pyRid == dartRid) {
          ok('跨语言一致性', 'Dart 与 Python 算出同一个 w_rid=$dartRid');
        } else {
          fail('跨语言一致性', 'Dart=$dartRid  Python=$pyRid');
        }
      }
    }
  }

  // 6. 直播状态（公开接口，无需 Cookie）
  print('\n[6] 直播状态接口（公开、无需 Cookie）');
  try {
    final List<LiveStatus> lives =
        await probeAdapter.fetchLiveStatus(<String>['2', '672328094']);
    if (lives.isEmpty) {
      warn('直播状态', '返回空列表');
    } else {
      for (final LiveStatus s in lives) {
        print('     uid=${s.upUid} ${s.uname}  live=${s.isLive}  room=${s.roomId}');
      }
      ok('直播状态', '解析出 ${lives.length} 条，公开接口可用');
    }
  } on ApiException catch (e) {
    fail('直播状态', '${e.code} ${e.message}');
  } catch (e) {
    fail('直播状态', '$e');
  }

  // 7. 需要 Cookie 的接口：验证错误分支
  print('\n[7] 需登录接口的失效检测');
  if (cookie.isEmpty) {
    try {
      await probeAdapter.fetchFollowings(selfUid: '2');
      warn('关注列表', '未登录却拿到数据（接口可能已放开限制）');
    } on ApiException catch (e) {
      if (e.isNotLogin) {
        ok('Cookie 失效检测', '正确识别 -101 未登录 → 会触发重新登录提示');
      } else {
        warn('关注列表', '返回 ${e.code} ${e.message}');
      }
    } catch (e) {
      warn('关注列表', '$e');
    }
  } else {
    try {
      final String? selfUid = _extractUid(cookie);
      final List<UpCreator> ups =
          await probeAdapter.fetchFollowings(selfUid: selfUid ?? '0');
      ok('关注列表', '拉取 ${ups.length} 位 UP 主');
      for (final UpCreator u in ups.take(5)) {
        print('     ${u.uid}  ${u.name}');
      }
      if (ups.isNotEmpty) {
        final DynamicPage page =
            await probeAdapter.fetchDynamics(uid: ups.first.uid);
        ok('动态抓取', '${page.items.length} 条，hasMore=${page.hasMore}');
        for (final FeedItem it in page.items.take(3)) {
          print('     [${feedKindLabel(it.kind)}] ${it.publishAt.toIso8601String()} ${it.title.isEmpty ? it.summary : it.title}');
        }
      }
    } on ApiException catch (e) {
      if (e.isNotLogin) {
        fail('关注列表', 'Cookie 已失效，请重新登录');
      } else if (e.isRiskControl) {
        warn('关注列表', '触发风控 ${e.code}，建议降频或补 buvid3');
      } else {
        warn('关注列表', '${e.code} ${e.message}');
      }
    }
  }

  // 8. 动态解析单测（离线样本，覆盖各 type）
  print('\n[8] 动态解析（离线样本）');
  _testDynamicParsing();

  print('\n${'═' * 64}');
  print(' 通过 $_passed  失败 $_failed');
  print('═' * 64);
  if (_failed > 0) exitCode = 1;
}

void _checkMd5(String input, String expected) {
  final String got = md5String(input);
  if (got == expected) {
    ok('md5("${input.length > 16 ? '${input.substring(0, 16)}…' : input}")', got);
  } else {
    fail('md5("$input")', 'got=$got want=$expected');
  }
}

void _checkEq(String name, String got, String want) {
  if (got == want) {
    ok(name, got);
  } else {
    fail(name, 'got=$got want=$want');
  }
}

String? _extractUid(String cookie) {
  for (final String seg in cookie.split(';')) {
    final int eq = seg.indexOf('=');
    if (eq <= 0) continue;
    if (seg.substring(0, eq).trim() == 'DedeUserID') {
      return seg.substring(eq + 1).trim();
    }
  }
  return null;
}

/// 调用 Python 独立实现交叉验证 w_rid，确认不是自说自话。
Future<String?> _pythonCrossCheck(String mixinKey) async {
  try {
    final ProcessResult r = await Process.run('python3', <String>[
      '-c',
      '''
import hashlib, urllib.parse
mixin = "$mixinKey"
p = {"mid":"2","pn":"1","ps":"30","platform":"web","wts":"1700000000"}
clean = {k:"".join(c for c in v if c not in "!'()*") for k,v in p.items()}
q = urllib.parse.urlencode(sorted(clean.items()))
print(q + "&w_rid=" + hashlib.md5((q+mixin).encode()).hexdigest())
''',
    ]);
    final String out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

void _testDynamicParsing() {
  // 构造各 type 的最小可用样本，验证字段抽取路径
  final List<Map<String, dynamic>> samples = <Map<String, dynamic>>[
    <String, dynamic>{
      '_label': 'type=8 视频',
      'desc': <String, dynamic>{
        'dynamic_id': 1001,
        'type': 8,
        'timestamp': 1700000000,
        'bvid': 'BV1xx411c7mD',
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗', 'face': '//i2.hdslb.com/a.jpg'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'item': <String, dynamic>{
          'title': '测试视频标题',
          'desc': '视频简介',
          'pic': '//i0.hdslb.com/cover.jpg',
        },
      }),
    },
    <String, dynamic>{
      '_label': 'type=2 图文',
      'desc': <String, dynamic>{
        'dynamic_id': 1002,
        'type': 2,
        'timestamp': 1700000100,
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'item': <String, dynamic>{
          'description': '图文正文',
          'pictures': <Map<String, dynamic>>[
            <String, dynamic>{'img_src': '//i0.hdslb.com/p1.jpg'},
          ],
        },
      }),
    },
    <String, dynamic>{
      '_label': 'type=4 文字',
      'desc': <String, dynamic>{
        'dynamic_id': 1003,
        'type': 4,
        'timestamp': 1700000200,
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'item': <String, dynamic>{'content': '纯文字动态'},
      }),
    },
    <String, dynamic>{
      '_label': 'type=1 转发',
      'desc': <String, dynamic>{
        'dynamic_id': 1004,
        'type': 1,
        'timestamp': 1700000300,
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'item': <String, dynamic>{'content': '转发理由'},
      }),
    },
    <String, dynamic>{
      '_label': 'type=64 专栏',
      'desc': <String, dynamic>{
        'dynamic_id': 1005,
        'type': 64,
        'timestamp': 1700000400,
        'rid': 88888,
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'title': '专栏标题',
        'summary': '专栏摘要',
        'banner_url': '//i0.hdslb.com/banner.jpg',
      }),
    },
    <String, dynamic>{
      '_label': 'type=2048 直播',
      'desc': <String, dynamic>{
        'dynamic_id': 1006,
        'type': 2048,
        'timestamp': 1700000500,
        'user_profile': <String, dynamic>{
          'info': <String, dynamic>{'uid': 2, 'uname': '碧诗'},
        },
      },
      'card': jsonEncode(<String, dynamic>{
        'live_play_info': <String, dynamic>{'title': '直播间标题', 'room_id': 1024},
      }),
    },
  ];

  for (final Map<String, dynamic> s in samples) {
    final String label = s['_label'] as String;
    s.remove('_label');
    final FeedItem? item = parseDynamicCard(s);
    if (item == null) {
      fail('解析 $label', '返回 null');
      continue;
    }
    final String brief = item.title.isEmpty ? item.summary : item.title;
    if (brief.isEmpty) {
      fail('解析 $label', '标题与摘要均为空');
    } else {
      ok('解析 $label',
          '${feedKindLabel(item.kind)} | ${item.upName} | $brief | ${item.url}');
    }
  }
}
