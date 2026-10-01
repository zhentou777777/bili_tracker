/// B 站适配器：所有请求在客户端直连，Cookie 由本地注入，服务端全程不参与。
library bilibili;

import 'dart:convert';

import '../core/http.dart';
import '../core/rules.dart';
import '../core/wbi.dart';
import 'models.dart';

/// 模拟浏览器的请求头，缺失会被判定为爬虫。
const String kBilibiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class BilibiliAdapter {
  BilibiliAdapter({
    required PlatformRule rule,
    required HttpSender sender,
    required CookieProvider cookies,
    required WbiSigner signer,
  })  : _rule = rule,
        _sender = sender,
        _cookies = cookies,
        _signer = signer;

  final PlatformRule _rule;
  final HttpSender _sender;
  final CookieProvider _cookies;
  final WbiSigner _signer;

  static const String platformId = 'bilibili';

  /// 取 WBI 密钥用；未登录也能拿到。
  Future<Map<String, dynamic>?> nav() async {
    final HttpResp resp = await _request('nav', <String, String>{});
    final Object? decoded = jsonDecode(resp.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  /// 当前登录用户的关注列表。
  Future<List<UpCreator>> fetchFollowings({
    required String selfUid,
    int page = 1,
  }) async {
    final HttpResp resp = await _request(
      'followings',
      <String, String>{'self_uid': selfUid, 'page': page.toString()},
    );
    final Map<String, dynamic> json = _decodeObject(resp);
    _throwIfApiError(json);

    final EndpointRule ep = _requireEndpoint('followings');
    final Object? list = getByPath(json, ep.listPath);
    if (list is! List) return const <UpCreator>[];

    return <UpCreator>[
      for (final Object? raw in list)
        if (raw is Map)
          _upFromGeneric(Map<String, dynamic>.from(raw), ep.itemMap),
    ];
  }

  /// 单个 UP 主的动态（space_history）。
  Future<DynamicPage> fetchDynamics({
    required String uid,
    String? offset,
  }) async {
    final HttpResp resp = await _request(
      'dynamics',
      <String, String>{'uid': uid, 'offset': offset ?? '0'},
    );
    final Map<String, dynamic> json = _decodeObject(resp);
    _throwIfApiError(json);

    final EndpointRule ep = _requireEndpoint('dynamics');
    final Object? list = getByPath(json, ep.listPath);
    final List<FeedItem> items = <FeedItem>[];
    if (list is List) {
      for (final Object? raw in list) {
        if (raw is! Map) continue;
        final FeedItem? item =
            parseDynamicCard(Map<String, dynamic>.from(raw), fallbackUid: uid);
        if (item != null) items.add(item);
      }
    }

    final Object? next = getByPath(json, ep.nextOffsetPath);
    final Object? hasMore = getByPath(json, ep.hasMorePath);
    return DynamicPage(
      items: items,
      nextOffset: next?.toString() ?? '0',
      hasMore: hasMore is num ? hasMore != 0 : hasMore == true,
    );
  }

  /// 单个 UP 主的视频投稿（需 WBI 签名）。
  Future<List<FeedItem>> fetchVideos({required String uid, int page = 1}) async {
    final HttpResp resp = await _request(
      'videos',
      <String, String>{'uid': uid, 'page': page.toString()},
    );
    final Map<String, dynamic> json = _decodeObject(resp);
    _throwIfApiError(json);

    final EndpointRule ep = _requireEndpoint('videos');
    final Object? list = getByPath(json, ep.listPath);
    if (list is! List) return const <FeedItem>[];

    final List<FeedItem> out = <FeedItem>[];
    for (final Object? raw in list) {
      if (raw is! Map) continue;
      final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
      final int? ts = m[ep.itemMap['time'] ?? 'created'] is int
          ? m[ep.itemMap['time'] ?? 'created'] as int
          : int.tryParse(m[ep.itemMap['time'] ?? 'created']?.toString() ?? '');
      final String bvid = (m[ep.itemMap['id'] ?? 'bvid'] ?? '').toString();
      out.add(
        FeedItem(
          platform: platformId,
          upUid: uid,
          itemId: bvid.isEmpty ? 'unknown_${m['aid']}' : bvid,
          kind: FeedKind.video,
          publishAt: ts != null
              ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
              : DateTime.now(),
          title: (m[ep.itemMap['title'] ?? 'title'] ?? '').toString(),
          summary: (m[ep.itemMap['desc'] ?? 'description'] ?? '').toString(),
          cover: _fixCover((m[ep.itemMap['cover'] ?? 'pic'] ?? '').toString()),
          url: bvid.isEmpty ? '' : 'https://www.bilibili.com/video/$bvid',
          extra: <String, dynamic>{
            'duration': m[ep.itemMap['duration'] ?? 'length'],
            'play': m[ep.itemMap['play'] ?? 'play'],
          },
        ),
      );
    }
    return out;
  }

  /// 批量查直播状态。
  ///
  /// 这是公开接口，实测无需 Cookie —— 后台轮询与服务端兜底都依赖它。
  Future<List<LiveStatus>> fetchLiveStatus(List<String> uids) async {
    if (uids.isEmpty) return const <LiveStatus>[];
    // 单次请求上限，避免 URL 过长被拒
    const int batch = 40;
    final List<LiveStatus> out = <LiveStatus>[];
    for (int i = 0; i < uids.length; i += batch) {
      final List<String> slice =
          uids.sublist(i, i + batch > uids.length ? uids.length : i + batch);
      final HttpResp resp = await _request(
        'live_status',
        const <String, String>{},
        repeatValues: slice,
      );
      final Map<String, dynamic> json = _decodeObject(resp);
      _throwIfApiError(json);

      final Object? data = json['data'];
      if (data is! Map) continue;
      for (final MapEntry<dynamic, dynamic> e in data.entries) {
        if (e.value is! Map) continue;
        final Map<String, dynamic> m = Map<String, dynamic>.from(e.value as Map);
        out.add(
          LiveStatus(
            platform: platformId,
            upUid: (m['uid'] ?? e.key ?? '').toString(),
            roomId: (m['room_id'] ?? '').toString(),
            isLive: (m['live_status'] is num ? m['live_status'] as num : 0) == 1,
            title: (m['title'] ?? '').toString(),
            uname: (m['uname'] ?? '').toString(),
            online: m['online'] is num ? (m['online'] as num).toInt() : 0,
            cover: (m['cover'] ?? m['face'] ?? '').toString(),
            startedAt: (m['live_time'] is num && (m['live_time'] as num) > 0)
                ? DateTime.fromMillisecondsSinceEpoch(
                    (m['live_time'] as num).toInt() * 1000,
                  )
                : null,
          ),
        );
      }
    }
    return out;
  }

  /// 用户信息（需 WBI 签名），用于手动添加 UP 主时补全资料。
  Future<UpCreator?> fetchUserInfo(String uid) async {
    final HttpResp resp = await _request('user_info', <String, String>{'uid': uid});
    final Map<String, dynamic> json = _decodeObject(resp);
    _throwIfApiError(json);
    final Object? data = json['data'];
    if (data is! Map) return null;
    final EndpointRule ep = _requireEndpoint('user_info');
    return _upFromGeneric(Map<String, dynamic>.from(data), ep.itemMap);
  }

  // ---------- 内部实现 ----------

  EndpointRule _requireEndpoint(String name) {
    final EndpointRule? ep = _rule.endpoint(name);
    if (ep == null) {
      throw StateError('规则文件缺少端点：$name（请更新平台规则 JSON）');
    }
    return ep;
  }

  Future<HttpResp> _request(
    String endpointName,
    Map<String, String> vars, {
    List<String>? repeatValues,
  }) async {
    final EndpointRule ep = _requireEndpoint(endpointName);

    final Map<String, String> params = renderParams(ep.params, vars);

    String query;
    if (ep.requireSign) {
      final String? signed = await _signer.signQuery(params);
      if (signed == null) {
        throw const ApiException(-403, 'WBI 密钥获取失败，无法签名');
      }
      query = signed;
    } else {
      final List<String> keys = params.keys.toList()..sort();
      query = <String>[
        for (final String k in keys) '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(params[k]!)}',
      ].join('&');
    }

    // 重复参数（uids[]=a&uids[]=b）追加在签名之后：该接口本身不参与签名
    if (ep.repeatParam != null && repeatValues != null) {
      for (final MapEntry<String, String> rp in ep.repeatParam!.entries) {
        for (final String v in repeatValues) {
          final String value = renderTemplate(rp.value, <String, String>{'uid': v});
          query = query.isEmpty
              ? '${Uri.encodeQueryComponent(rp.key)}=${Uri.encodeQueryComponent(value)}'
              : '$query&${Uri.encodeQueryComponent(rp.key)}=${Uri.encodeQueryComponent(value)}';
        }
      }
    }

    final String url = query.isEmpty ? ep.url : '${ep.url}?$query';

    final Map<String, String> headers = <String, String>{
      'User-Agent': kBilibiliUserAgent,
      'Referer': renderTemplate(ep.referer, vars),
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Origin': 'https://space.bilibili.com',
    };

    final String cookie = await _cookies();
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final HttpResp resp = await _sender.get(url, headers: headers);

    if (!resp.isOk) {
      throw ApiException(-resp.status, 'HTTP ${resp.status}', statusCode: resp.status);
    }
    return resp;
  }

  static Map<String, dynamic> _decodeObject(HttpResp resp) {
    final Object? decoded = jsonDecode(resp.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    // 风控页会直接返回 HTML，这里统一转成可识别的错误
    throw ApiException(-resp.status, '响应不是 JSON（可能被风控拦截）', statusCode: resp.status);
  }

  static void _throwIfApiError(Map<String, dynamic> json) {
    final Object? code = json['code'];
    if (code is num && code != 0) {
      throw ApiException(
        code.toInt(),
        (json['message'] ?? json['msg'] ?? '接口返回错误').toString(),
      );
    }
  }

  static UpCreator _upFromGeneric(
    Map<String, dynamic> m,
    Map<String, String> itemMap,
  ) {
    String pick(String fallback, String? path) =>
        (m[path ?? fallback] ?? m[fallback] ?? '').toString();
    return UpCreator(
      platform: platformId,
      uid: pick('mid', itemMap['uid']),
      name: pick('uname', itemMap['name']),
      face: _fixCover(pick('face', itemMap['face'])),
      sign: pick('sign', itemMap['sign']),
      followedAt: DateTime.now(),
    );
  }

  /// B 站封面常返回 protocol-relative 或 http，统一成 https 便于缓存。
  static String _fixCover(String url) {
    if (url.isEmpty) return '';
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) return 'https${url.substring(4)}';
    return url;
  }
}

/// Cookie 供给器：由安全存储层注入，Adapter 不关心 Cookie 从哪来。
typedef CookieProvider = Future<String> Function();

/// 动态分页结果。
class DynamicPage {
  const DynamicPage({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
  });

  final List<FeedItem> items;
  final String nextOffset;
  final bool hasMore;
}

/// 解析 space_history 的单条 card。
///
/// 结构嵌套且 `card` 字段是 JSON 字符串，各 type 字段位置不一致，
/// 这里逐个分支处理；取不到就降级为摘要，绝不因为单条异常拖垮整页。
FeedItem? parseDynamicCard(
  Map<String, dynamic> card, {
  String fallbackUid = '',
}) {
  final Object? descRaw = card['desc'];
  if (descRaw is! Map) return null;
  final Map<String, dynamic> desc = Map<String, dynamic>.from(descRaw);

  final String dynamicId = (desc['dynamic_id'] ?? desc['rid'] ?? '').toString();
  if (dynamicId.isEmpty) return null;

  final int type = desc['type'] is num ? (desc['type'] as num).toInt() : 0;
  final int ts = desc['timestamp'] is num ? (desc['timestamp'] as num).toInt() : 0;

  String uid = fallbackUid;
  String uname = '';
  String face = '';
  final Object? profile = desc['user_profile'];
  if (profile is Map) {
    final Object? info = profile['info'];
    if (info is Map) {
      uid = (info['uid'] ?? uid).toString();
      uname = (info['uname'] ?? '').toString();
      face = (info['face'] ?? '').toString();
    }
  }

  final Map<String, dynamic> cardObj = _asMap(card['card']);
  final Map<String, dynamic> item = _asMap(cardObj['item']).isNotEmpty
      ? _asMap(cardObj['item'])
      : cardObj;

  String title = '';
  String summary = '';
  String cover = '';
  String url = '';
  FeedKind kind = FeedKind.unknown;

  switch (type) {
    case 8: // 投稿视频
      kind = FeedKind.video;
      title = (item['title'] ?? '').toString();
      summary = (item['desc'] ?? item['description'] ?? item['dynamic'] ?? '')
          .toString();
      cover = (item['pic'] ?? '').toString();
      final String bvid = (desc['bvid'] ?? item['bvid'] ?? '').toString();
      if (bvid.isNotEmpty) url = 'https://www.bilibili.com/video/$bvid';
      break;
    case 2: // 图文
      kind = FeedKind.image;
      summary = (item['description'] ?? item['content'] ?? '').toString();
      final Object? pics = item['pictures'];
      if (pics is List && pics.isNotEmpty && pics.first is Map) {
        cover = (pics.first['img_src'] ?? '').toString();
      }
      break;
    case 4: // 纯文字
      kind = FeedKind.text;
      summary = (item['content'] ?? item['description'] ?? '').toString();
      break;
    case 1: // 转发
      kind = FeedKind.repost;
      summary = (item['content'] ?? '').toString();
      break;
    case 64: // 专栏
      kind = FeedKind.article;
      title = (cardObj['title'] ?? item['title'] ?? '').toString();
      summary = (cardObj['summary'] ?? cardObj['desc'] ?? '').toString();
      cover = (cardObj['banner_url'] ?? cardObj['image_urls']?.first ?? '')
          .toString();
      final String cvid = (desc['rid'] ?? cardObj['id'] ?? '').toString();
      if (cvid.isNotEmpty) url = 'https://www.bilibili.com/read/cv$cvid';
      break;
    case 2048: // 直播
      kind = FeedKind.live;
      final Map<String, dynamic> live = _asMap(cardObj['live_play_info']).isNotEmpty
          ? _asMap(cardObj['live_play_info'])
          : cardObj;
      title = (live['title'] ?? live['room_title'] ?? '').toString();
      summary = (live['area_name'] ?? '').toString();
      cover = (live['cover'] ?? live['user_cover'] ?? '').toString();
      final String roomId = (live['room_id'] ?? desc['rid'] ?? '').toString();
      if (roomId.isNotEmpty) url = 'https://live.bilibili.com/$roomId';
      break;
    default:
      kind = FeedKind.unknown;
      summary = (item['content'] ?? item['description'] ?? item['dynamic'] ?? '')
          .toString();
  }

  // 兜底：内容为空时用原始结构裁一段，避免日历里出现空白条目
  if (summary.isEmpty && title.isEmpty) {
    summary = _digest(cardObj);
  }

  return FeedItem(
    platform: BilibiliAdapter.platformId,
    upUid: uid,
    itemId: dynamicId,
    kind: kind,
    publishAt: DateTime.fromMillisecondsSinceEpoch(
      ts > 0 ? ts * 1000 : DateTime.now().millisecondsSinceEpoch,
    ),
    upName: uname,
    upFace: BilibiliAdapter._fixCover(face),
    title: title,
    summary: summary,
    cover: BilibiliAdapter._fixCover(cover),
    url: url,
  );
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.trim().startsWith('{')) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
  return const <String, dynamic>{};
}

String _digest(Map<String, dynamic> m) {
  final String s = jsonEncode(m);
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}
