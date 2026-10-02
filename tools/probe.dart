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
    // 动态端点必须是新版 polymer 接口 —— 旧 dynamic_svr/space_history 已 404，
    // 这条断言就是为了防止回退到死端点。
    final String dynUrl = bili.endpoint('dynamics')?.url ?? '';
    if (dynUrl.contains('polymer/web-dynamic/v1/feed/space')) {
      ok('动态端点', dynUrl);
    } else {
      fail('动态端点', '仍是旧接口，会 404：$dynUrl');
    }
    final String liveHistUrl = bili.endpoint('live_history')?.url ?? '';
    if (liveHistUrl.contains('history/cursor')) {
      ok('观看历史端点', liveHistUrl);
    } else {
      fail('观看历史端点', '缺失或地址不对：$liveHistUrl');
    }
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

  // 7. 需要 Cookie 的接口
  print('\n[7] 需登录接口（关注列表 / 动态 / 最近观看的直播）');
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

    // 动态端点存活探测：404 = 端点已下线（正是本次要修的 bug）
    try {
      final DynamicPage page = await probeAdapter.fetchDynamics(uid: '2');
      if (page.items.isEmpty) {
        warn('动态端点', 'HTTP 200 但 0 条（无 buvid3 时会被限制，属预期）');
      } else {
        ok('动态端点', '解析出 ${page.items.length} 条');
      }
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        fail('动态端点', 'HTTP 404 —— 端点已下线，必须更新规则文件');
      } else if (e.isRiskControl) {
        warn('动态端点', 'HTTP ${e.statusCode} 风控（缺 buvid3 时正常）—— 端点本身存在');
      } else {
        warn('动态端点', '${e.code} ${e.message}');
      }
    } catch (e) {
      warn('动态端点', '$e');
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

    // 最近观看的直播：自动追更策略的数据源
    try {
      final List<WatchedLive> watched = await probeAdapter.fetchWatchedLives();
      ok('最近观看的直播', '${watched.length} 场');
      for (final WatchedLive w in watched.take(5)) {
        print('     uid=${w.uid} ${w.name} room=${w.roomId} ${w.viewedAt}');
      }
    } on ApiException catch (e) {
      warn('最近观看的直播', '${e.code} ${e.message}');
    } catch (e) {
      warn('最近观看的直播', '$e');
    }
  }

  // 8. 新版动态解析单测（离线样本，覆盖各 major 分支）
  print('\n[8] 新版动态解析（离线样本）');
  _testDynamicParsing();

  // 9. 观看历史解析单测（离线样本）
  print('\n[9] 最近观看直播解析（离线样本）');
  _testLiveHistoryParsing();

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

/// 构造一条最小可用的新版动态 item。
Map<String, dynamic> _item({
  required String id,
  required String type,
  String name = '碧诗',
  int mid = 2,
  int pubTs = 1783878096,
  Map<String, dynamic>? dyn,
  Map<String, dynamic>? stat,
  Map<String, dynamic>? orig,
}) =>
    <String, dynamic>{
      'id_str': id,
      'type': type,
      'modules': <String, dynamic>{
        'module_author': <String, dynamic>{
          'mid': mid,
          'name': name,
          'face': '//i2.hdslb.com/face.jpg',
          'pub_ts': pubTs,
        },
        'module_dynamic': dyn ?? <String, dynamic>{},
        if (stat != null) 'module_stat': stat,
      },
      if (orig != null) 'orig': orig,
    };

/// 新版动态结构离线样本：字段与 2026-10 实测响应一致（已裁剪无关字段）。
void _testDynamicParsing() {
  final List<({String label, Map<String, dynamic> item, FeedKind kind, String urlPart})>
      samples =
      <({String label, Map<String, dynamic> item, FeedKind kind, String urlPart})>[
    (
      label: '视频 MAJOR_TYPE_ARCHIVE',
      kind: FeedKind.video,
      urlPart: 'https://www.bilibili.com/video/BV1ujNV6qEXg',
      item: _item(
        id: '1224236172397510665',
        type: 'DYNAMIC_TYPE_AV',
        dyn: <String, dynamic>{
          'desc': null,
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_ARCHIVE',
            'archive': <String, dynamic>{
              'bvid': 'BV1ujNV6qEXg',
              'title': '帮不帮？',
              'desc': '去还是不去？',
              'cover': 'http://i2.hdslb.com/bfs/archive/x.jpg',
              'duration_text': '00:22',
              'jump_url': '//www.bilibili.com/video/BV1ujNV6qEXg',
              'stat': <String, dynamic>{'play': '70.9万'},
            },
          },
        },
      ),
    ),
    (
      label: '图文 MAJOR_TYPE_OPUS（有配图）',
      kind: FeedKind.image,
      urlPart: 'https://www.bilibili.com/opus/1253052791646060563',
      item: _item(
        id: '1253052791646060563',
        type: 'DYNAMIC_TYPE_DRAW',
        name: 'A-SOUL_Official',
        mid: 703007996,
        dyn: <String, dynamic>{
          'desc': null,
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'jump_url': '//www.bilibili.com/opus/1253052791646060563',
              'title': '',
              'summary': <String, dynamic>{'text': '周边余量已上架，欢迎购入~'},
              'pics': <Map<String, dynamic>>[
                <String, dynamic>{'url': '//i0.hdslb.com/p1.jpg', 'width': 1200},
              ],
            },
          },
        },
        stat: <String, dynamic>{'like': <String, dynamic>{'count': 789}},
      ),
    ),
    (
      label: '纯文字 MAJOR_TYPE_OPUS（无配图）',
      kind: FeedKind.text,
      urlPart: 'https://www.bilibili.com/opus/1253728007744389129',
      item: _item(
        id: '1253728007744389129',
        type: 'DYNAMIC_TYPE_WORD',
        dyn: <String, dynamic>{
          'desc': <String, dynamic>{'text': '今天休息一天，明天见~'},
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'jump_url': '//www.bilibili.com/opus/1253728007744389129',
              'summary': <String, dynamic>{'text': '今天休息一天，明天见~'},
              'pics': <Object?>[],
            },
          },
        },
      ),
    ),
    (
      label: '转发（含原动态）',
      kind: FeedKind.repost,
      urlPart: 'https://www.bilibili.com/video/BV19PMr6FEfw',
      item: _item(
        id: '1233396749236699159',
        type: 'DYNAMIC_TYPE_FORWARD',
        dyn: <String, dynamic>{
          'desc': <String, dynamic>{'text': '翻得好！'},
        },
        orig: _item(
          id: '1233396000000000000',
          type: 'DYNAMIC_TYPE_AV',
          name: '横川是川崽耶',
          mid: 12345,
          dyn: <String, dynamic>{
            'major': <String, dynamic>{
              'type': 'MAJOR_TYPE_ARCHIVE',
              'archive': <String, dynamic>{
                'bvid': 'BV19PMr6FEfw',
                'title': '请 汤 上 身',
                'cover': '//i1.hdslb.com/cover.jpg',
              },
            },
          },
        ),
      ),
    ),
    (
      label: '专栏 MAJOR_TYPE_ARTICLE',
      kind: FeedKind.article,
      urlPart: 'https://www.bilibili.com/read/cv88888',
      item: _item(
        id: '1000000000000000005',
        type: 'DYNAMIC_TYPE_ARTICLE',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_ARTICLE',
            'article': <String, dynamic>{
              'id': 88888,
              'title': '专栏标题',
              'desc': '专栏摘要',
              'covers': <String>['//i0.hdslb.com/banner.jpg'],
              'jump_url': '//www.bilibili.com/read/cv88888',
            },
          },
        },
      ),
    ),
    (
      label: '直播 MAJOR_TYPE_LIVE_RCMD',
      kind: FeedKind.live,
      urlPart: 'https://live.bilibili.com/22637261',
      item: _item(
        id: '1000000000000000006',
        type: 'DYNAMIC_TYPE_LIVE_RCMD',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_LIVE_RCMD',
            'live_rcmd': <String, dynamic>{
              // 真实响应里 content 是被转义的 JSON 字符串
              'content': jsonEncode(<String, dynamic>{
                'live_play_info': <String, dynamic>{
                  'room_id': 22637261,
                  'title': '今晚八点开播',
                  'area_name': '虚拟主播',
                  'online': 1234,
                  'cover': '//i0.hdslb.com/live.jpg',
                },
              }),
            },
          },
        },
      ),
    ),
    (
      label: '通用卡片 MAJOR_TYPE_COMMON',
      kind: FeedKind.unknown,
      urlPart: 'https://www.bilibili.com',
      item: _item(
        id: '1000000000000000007',
        type: 'DYNAMIC_TYPE_COMMON_SQUARE',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_COMMON',
            'common': <String, dynamic>{
              'title': '通用卡片标题',
              'desc': '通用卡片描述',
              'jump_url': '//www.bilibili.com/blackboard/activity-x.html',
            },
          },
        },
      ),
    ),
  ];

  for (final ({String label, Map<String, dynamic> item, FeedKind kind, String urlPart}) s
      in samples) {
    final FeedItem? it = parseDynamicItem(s.item);
    if (it == null) {
      fail('解析 ${s.label}', '返回 null');
      continue;
    }
    final String brief = it.title.isEmpty ? it.summary : it.title;
    if (brief.isEmpty) {
      fail('解析 ${s.label}', '标题与摘要均为空');
      continue;
    }
    if (it.kind != s.kind) {
      fail('解析 ${s.label}', '类型=${it.kind.name} 期望=${s.kind.name}');
      continue;
    }
    if (!it.url.contains(s.urlPart)) {
      fail('解析 ${s.label}', 'url=${it.url} 期望包含 ${s.urlPart}');
      continue;
    }
    ok('解析 ${s.label}',
        '${feedKindLabel(it.kind)} | ${it.upName} | $brief | ${it.url}');
  }

  // 转发必须把原动态正文折进来，否则界面上只剩一句「分享动态」
  final FeedItem? repost = parseDynamicItem(_item(
    id: '1',
    type: 'DYNAMIC_TYPE_FORWARD',
    dyn: <String, dynamic>{
      'desc': <String, dynamic>{'text': '翻得好！'},
    },
    orig: _item(
      id: '2',
      type: 'DYNAMIC_TYPE_DRAW',
      name: '横川是川崽耶',
      dyn: <String, dynamic>{
        'major': <String, dynamic>{
          'type': 'MAJOR_TYPE_OPUS',
          'opus': <String, dynamic>{
            'summary': <String, dynamic>{'text': '请 汤 上 身'},
            'pics': <Map<String, dynamic>>[
              <String, dynamic>{'url': '//i0.hdslb.com/p.jpg'},
            ],
          },
        },
      },
    ),
  ));
  if (repost != null && repost.summary.contains('请 汤 上 身')) {
    ok('转发折入原动态正文', repost.summary);
  } else {
    fail('转发折入原动态正文', '实际=${repost?.summary}');
  }

  // id 缺失必须返回 null（不能让半条脏数据进库）
  if (parseDynamicItem(<String, dynamic>{'type': 'DYNAMIC_TYPE_WORD'}) == null) {
    ok('缺 id_str 返回 null', '防脏数据');
  } else {
    fail('缺 id_str 返回 null', '却解析出了对象');
  }
}

/// 最近观看直播：离线样本 + 边界（缺 author_mid 必须丢弃）。
void _testLiveHistoryParsing() {
  final WatchedLive? w = parseLiveHistoryItem(<String, dynamic>{
    'title': '今晚八点开播',
    'cover': '//i0.hdslb.com/live.jpg',
    'uri': 'https://live.bilibili.com/22637261',
    'history': <String, dynamic>{'oid': 22637261, 'business': 'live'},
    'author_name': '嘉然今天吃什么',
    'author_face': '//i1.hdslb.com/face.jpg',
    'author_mid': 672328094,
    'view_at': 1786000000,
    'tag_name': '直播',
  });
  if (w == null) {
    fail('解析直播历史', '返回 null');
  } else if (w.uid == '672328094' &&
      w.roomId == '22637261' &&
      w.name == '嘉然今天吃什么' &&
      w.viewedAt?.year == 2026 &&
      w.face.startsWith('https://')) {
    ok('解析直播历史',
        'uid=${w.uid} ${w.name} room=${w.roomId} ${w.viewedAt} face=${w.face}');
  } else {
    fail('解析直播历史', '字段不对：uid=${w.uid} room=${w.roomId} name=${w.name}');
  }

  // history.oid 缺失时从 uri 里抠房间号
  final WatchedLive? w2 = parseLiveHistoryItem(<String, dynamic>{
    'title': '溜了溜了',
    'uri': 'https://live.bilibili.com/1024',
    'history': <String, dynamic>{'business': 'live'},
    'author_mid': 2,
    'author_name': '碧诗',
  });
  if (w2?.roomId == '1024') {
    ok('uri 兜底取房间号', w2!.roomId);
  } else {
    fail('uri 兜底取房间号', '实际=${w2?.roomId}');
  }

  if (parseLiveHistoryItem(<String, dynamic>{'title': '无主播信息'}) == null) {
    ok('缺 author_mid 返回 null', '没有 UID 就无法和关注列表比对');
  } else {
    fail('缺 author_mid 返回 null', '却解析出了对象');
  }
}
