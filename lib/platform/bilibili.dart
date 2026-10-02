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

  /// 当前登录用户的关注列表（单页，仅返回条目）。
  Future<List<UpCreator>> fetchFollowings({
    required String selfUid,
    int page = 1,
  }) async =>
      (await fetchFollowingsPage(selfUid: selfUid, page: page)).items;

  /// 关注列表单页 + 关注总数。
  ///
  /// 相比 [fetchFollowings] 多返回 `total`（接口的 `data.total`），
  /// 供界面显示「已获取 x / 共 y」的进度，并据此判断是否已翻完。
  ///
  /// 本方法**只读**，不写数据库 —— 是否追更由用户在列表里勾选后决定。
  Future<FollowPage> fetchFollowingsPage({
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
    final List<UpCreator> items = <UpCreator>[
      if (list is List)
        for (final Object? raw in list)
          if (raw is Map)
            _upFromGeneric(Map<String, dynamic>.from(raw), ep.itemMap),
    ];

    int total = -1;
    if (ep.totalPath.isNotEmpty) {
      final Object? rawTotal = getByPath(json, ep.totalPath);
      if (rawTotal is num) total = rawTotal.toInt();
    }

    return FollowPage(
      items: items,
      total: total,
      // 每页条数取自规则文件的 ps 参数，规则改了也不会误判「没有下一页」
      hasMore: items.isNotEmpty && items.length >= _followPageSize(ep),
    );
  }

  /// 规则文件里 followings 端点的每页条数（取不到时按 B 站默认 50）。
  static int _followPageSize(EndpointRule ep) {
    final int? ps = int.tryParse(ep.params['ps'] ?? '');
    return ps != null && ps > 0 ? ps : 50;
  }

  /// 单个 UP 主的动态（新版 polymer 空间动态接口）。
  ///
  /// 历史背景：旧接口 `api.vc.bilibili.com/dynamic_svr/space_history` 已下线
  /// （实测 HTTP 404，返回错误页而非 JSON），这是「无法获取动态」的直接原因。
  ///
  /// 两个必须注意的细节：
  /// 1. **首屏 offset 传空串**（与 B 站网页端一致）。另有一次实测 `offset=0`
  ///    返回 `code:0` 但 `items` 为空；但同一批请求都处于 -352 限流状态，
  ///    无法把「offset 的锅」和「限流的锅」分开，所以这里不下定论，
  ///    只保持与网页端一致的做法。
  /// 2. 该接口**需要设备指纹 buvid3**，缺失时返回 HTTP 412（风控）。
  ///    指纹由 `DioHttpSender.ensureDeviceCookies()` 或登录 Cookie 保证。
  Future<DynamicPage> fetchDynamics({
    required String uid,
    String? offset,
  }) async {
    final HttpResp resp = await _request(
      'dynamics',
      <String, String>{'uid': uid, 'offset': offset ?? ''},
    );
    final Map<String, dynamic> json = _decodeObject(resp);
    _throwIfApiError(json);

    // 空 offset 会渲染成 `offset=`，这与「不传」等价；保险起见再兜一层
    final EndpointRule ep = _requireEndpoint('dynamics');
    final Object? list = getByPath(json, ep.listPath);
    final List<FeedItem> items = <FeedItem>[];
    if (list is List) {
      for (final Object? raw in list) {
        if (raw is! Map) continue;
        final FeedItem? item =
            parseDynamicItem(Map<String, dynamic>.from(raw), fallbackUid: uid);
        if (item != null) items.add(item);
      }
    }

    final Object? next = getByPath(json, ep.nextOffsetPath);
    final Object? hasMore = getByPath(json, ep.hasMorePath);
    final String nextOffset = next?.toString() ?? '';
    return DynamicPage(
      items: items,
      nextOffset: nextOffset,
      // 没有下一页游标时也视为到底，避免调用方拿着一串空 offset 反复请求
      hasMore: (hasMore is num ? hasMore != 0 : hasMore == true) &&
          nextOffset.isNotEmpty,
    );
  }

  /// 最近观看的直播记录（需登录）。
  ///
  /// 返回按观看时间倒序的记录，只保留能拿到主播 UID 的条目 ——
  /// 调用方拿它和关注列表求交集，实现「自动追更最近观看直播的已关注主播」。
  ///
  /// [maxPages] 是翻页上限（每页 30 条）。翻页靠上一页返回的
  /// `data.cursor`；**第 2 页起任何异常都只是停止翻页**，已取到的记录照常返回
  /// （首页失败才抛，因为那说明登录态或接口本身有问题，必须让调用方知道）。
  Future<List<WatchedLive>> fetchWatchedLives({int maxPages = 3}) async {
    final List<WatchedLive> out = <WatchedLive>[];
    final Set<String> seenRoom = <String>{};

    String max = '';
    String business = '';
    String viewAt = '';

    for (int page = 0; page < maxPages; page++) {
      Map<String, dynamic> json;
      try {
        final HttpResp resp = await _request('live_history', <String, String>{
          'max': max,
          'business': business,
          'view_at': viewAt,
        });
        json = _decodeObject(resp);
        _throwIfApiError(json);
      } catch (_) {
        // 首页失败必须让调用方知道（可能是 Cookie 失效）；
        // 后续页失败就停在上一页，别把已经拿到的数据一起丢掉。
        if (page == 0) rethrow;
        break;
      }

      final Object? list = getByPath(json, 'data.list');
      if (list is! List || list.isEmpty) break;

      int added = 0;
      for (final Object? raw in list) {
        if (raw is! Map) continue;
        final WatchedLive? w =
            parseLiveHistoryItem(Map<String, dynamic>.from(raw));
        if (w == null) continue;
        // 同一间直播间只保留最近一次观看
        final String dedupeKey = w.roomId.isNotEmpty ? w.roomId : w.uid;
        if (!seenRoom.add(dedupeKey)) continue;
        out.add(w);
        added++;
      }

      // 游标：拿不到就不再往下翻
      final Object? cursor = getByPath(json, 'data.cursor');
      if (cursor is! Map || added == 0) break;
      final Map<String, dynamic> c = Map<String, dynamic>.from(cursor);
      final String nextMax = (c['max'] ?? '').toString();
      final String nextViewAt = (c['view_at'] ?? '').toString();
      final String nextBusiness = (c['business'] ?? '').toString();
      if (nextMax.isEmpty || nextViewAt.isEmpty || nextViewAt == viewAt) break;
      max = nextMax;
      business = nextBusiness;
      viewAt = nextViewAt;

      // 翻页之间留出间隔，避免连续请求被风控
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    return out;
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

/// 关注列表的单页结果。
class FollowPage {
  const FollowPage({
    required this.items,
    required this.total,
    required this.hasMore,
  });

  final List<UpCreator> items;

  /// 接口返回的关注总数；取不到时为 -1。
  final int total;

  /// 是否还有下一页。
  final bool hasMore;
}

/// 解析新版空间动态接口（`x/polymer/web-dynamic/v1/feed/space`）的单条 item。
///
/// 结构：`{ id_str, type, modules: { module_author, module_dynamic, module_stat }, orig }`，
/// 其中 `module_dynamic.major` 按 `major.type` 分派，各分支字段位置互不相同。
/// 单条解析失败绝不允许拖垮整页，因此全部走「取不到就降级」。
///
/// 对应关系：
/// - `module_author.pub_ts` → 发布时间（秒）
/// - `module_dynamic.desc.text` → 动态正文（图片/文字动态的正文就在这里）
/// - `major.archive` / `major.opus` / `major.draw` / `major.article` / `major.live_rcmd` …→ 主内容
/// - `orig` → 转发链的原动态（结构与 item 同构）
FeedItem? parseDynamicItem(
  Map<String, dynamic> item, {
  String fallbackUid = '',
}) {
  final String dynamicId = (item['id_str'] ?? '').toString();
  if (dynamicId.isEmpty) return null;

  final Map<String, dynamic> modules = _asMap(item['modules']);
  final Map<String, dynamic> author = _asMap(modules['module_author']);
  final String itemType = (item['type'] ?? '').toString();

  final String uid = (author['mid'] ?? fallbackUid).toString();
  final String uname = (author['name'] ?? '').toString();
  final String face = (author['face'] ?? '').toString();
  final int ts = author['pub_ts'] is num ? (author['pub_ts'] as num).toInt() : 0;

  final _DynamicBody body = _readDynamicBody(itemType, modules);

  String title = body.title;
  String summary = body.summary;
  String cover = body.cover;
  String url = body.url;
  FeedKind kind = body.kind;
  final Map<String, dynamic> extra = <String, dynamic>{...body.extra};

  // 转发：把原动态正文折进摘要，否则界面上只剩一句「分享动态」看不出内容
  if (itemType == 'DYNAMIC_TYPE_FORWARD') {
    kind = FeedKind.repost;
    final Map<String, dynamic> orig = _asMap(item['orig']);
    final Map<String, dynamic> origModules = _asMap(orig['modules']);
    final _DynamicBody og = _readDynamicBody(
      (orig['type'] ?? '').toString(),
      origModules,
    );
    final String origText = og.title.isNotEmpty ? og.title : og.summary;
    if (origText.isNotEmpty) {
      final String origName =
          (_asMap(origModules['module_author'])['name'] ?? '').toString();
      final String quoted = origName.isEmpty ? origText : '@$origName：$origText';
      summary = summary.isEmpty ? '转发 $quoted' : '$summary｜转发 $quoted';
    }
    if (cover.isEmpty) cover = og.cover;
    if (url.isEmpty) url = og.url;
    if (og.kind != FeedKind.unknown) extra['origin_kind'] = og.kind.name;
  }

  // 兜底：正文与标题都为空时给一个可辨识的占位，避免日历里出现空白条目
  if (title.isEmpty && summary.isEmpty) {
    summary = '（${feedKindLabel(kind)}动态）';
  }
  if (url.isEmpty) url = 'https://www.bilibili.com/opus/$dynamicId';

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
    title: _clip(title),
    summary: _clip(summary),
    cover: BilibiliAdapter._fixCover(cover),
    url: url,
    extra: extra.isEmpty ? null : extra,
  );
}

/// 解析「最近观看的直播」单条记录（`x/web-interface/history/cursor?type=live`）。
///
/// - `author_mid` 是主播 UID（和关注列表比对就用它）
/// - `history.oid` 是直播间号，缺失时从 `uri`（`https://live.bilibili.com/{房间号}`）里抠
/// - `view_at` 是观看时间（秒）
///
/// 拿不到 UID 的条目直接返回 null —— 没有 UID 就无法判断是否已关注。
WatchedLive? parseLiveHistoryItem(Map<String, dynamic> item) {
  final String uid = (item['author_mid'] ?? item['mid'] ?? '').toString();
  if (uid.isEmpty || uid == '0') return null;

  String roomId = '';
  final Object? history = item['history'];
  if (history is Map && history['oid'] is num) {
    final int oid = (history['oid'] as num).toInt();
    if (oid > 0) roomId = oid.toString();
  }
  if (roomId.isEmpty) {
    final RegExpMatch? m = RegExp(r'live\.bilibili\.com/(\d+)')
        .firstMatch((item['uri'] ?? '').toString());
    if (m != null) roomId = m.group(1)!;
  }

  final int ts = item['view_at'] is num ? (item['view_at'] as num).toInt() : 0;
  final String t = (item['title'] ?? '').toString();
  final String showTitle = (item['show_title'] ?? '').toString();

  return WatchedLive(
    uid: uid,
    name: (item['author_name'] ?? '').toString(),
    face: BilibiliAdapter._fixCover((item['author_face'] ?? '').toString()),
    roomId: roomId,
    title: t.isNotEmpty ? t : showTitle,
    cover: BilibiliAdapter._fixCover((item['cover'] ?? '').toString()),
    viewedAt: ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts * 1000) : null,
  );
}

/// 一条动态的正文提取结果（自己的动态与转发链里的原动态共用同一套逻辑）。
class _DynamicBody {
  const _DynamicBody({
    this.title = '',
    this.summary = '',
    this.cover = '',
    this.url = '',
    this.kind = FeedKind.unknown,
    this.extra = const <String, dynamic>{},
  });

  final String title;
  final String summary;
  final String cover;
  final String url;
  final FeedKind kind;
  final Map<String, dynamic> extra;
}

_DynamicBody _readDynamicBody(
  String itemType,
  Map<String, dynamic> modules,
) {
  final Map<String, dynamic> dyn = _asMap(modules['module_dynamic']);
  final Map<String, dynamic> major = _asMap(dyn['major']);
  final String majorType = (major['type'] ?? '').toString();
  // 图片/文字动态的正文就在 module_dynamic.desc.text
  final String descText = (_asMap(dyn['desc'])['text'] ?? '').toString();

  String title = '';
  String summary = descText;
  String cover = '';
  String url = '';
  FeedKind kind = _kindFromItemType(itemType);
  final Map<String, dynamic> extra = <String, dynamic>{};

  switch (majorType) {
    case 'MAJOR_TYPE_ARCHIVE':
      final Map<String, dynamic> a = _asMap(major['archive']);
      kind = FeedKind.video;
      title = (a['title'] ?? '').toString();
      if (summary.isEmpty) summary = (a['desc'] ?? '').toString();
      cover = (a['cover'] ?? '').toString();
      final String bvid = (a['bvid'] ?? '').toString();
      url = bvid.isEmpty
          ? _fixJump((a['jump_url'] ?? '').toString())
          : 'https://www.bilibili.com/video/$bvid';
      extra['duration'] = a['duration_text'];
      extra['play'] = _asMap(a['stat'])['play'];
      break;

    case 'MAJOR_TYPE_PGC':
      final Map<String, dynamic> p = _asMap(major['pgc']);
      kind = FeedKind.video;
      title = (p['title'] ?? '').toString();
      if (summary.isEmpty) summary = (p['desc'] ?? '').toString();
      cover = (p['cover'] ?? '').toString();
      url = _fixJump((p['jump_url'] ?? '').toString());
      break;

    case 'MAJOR_TYPE_OPUS':
      // itemOpusStyle 下图文/文字动态都走这里，靠有没有配图区分
      final Map<String, dynamic> o = _asMap(major['opus']);
      title = (o['title'] ?? '').toString();
      final String opusText = (_asMap(o['summary'])['text'] ?? '').toString();
      if (opusText.isNotEmpty) summary = opusText;
      final List<Object?> pics =
          o['pics'] is List ? (o['pics'] as List).cast<Object?>() : const <Object?>[];
      if (pics.isNotEmpty && pics.first is Map) {
        cover = (_asMap(pics.first)['url'] ?? '').toString();
      }
      kind = pics.isNotEmpty ? FeedKind.image : FeedKind.text;
      url = _fixJump((o['jump_url'] ?? '').toString());
      if (pics.isNotEmpty) extra['pic_count'] = pics.length;
      break;

    case 'MAJOR_TYPE_DRAW':
      final Map<String, dynamic> d = _asMap(major['draw']);
      kind = FeedKind.image;
      final List<Object?> items = d['items'] is List
          ? (d['items'] as List).cast<Object?>()
          : const <Object?>[];
      if (items.isNotEmpty && items.first is Map) {
        cover = (_asMap(items.first)['src'] ?? '').toString();
      }
      if (items.isNotEmpty) extra['pic_count'] = items.length;
      break;

    case 'MAJOR_TYPE_ARTICLE':
      final Map<String, dynamic> a = _asMap(major['article']);
      kind = FeedKind.article;
      title = (a['title'] ?? '').toString();
      if (summary.isEmpty) summary = (a['desc'] ?? '').toString();
      final Object? covers = a['covers'];
      if (covers is List && covers.isNotEmpty) cover = covers.first.toString();
      final String cvid = (a['id'] ?? '').toString();
      url = cvid.isEmpty
          ? _fixJump((a['jump_url'] ?? '').toString())
          : 'https://www.bilibili.com/read/cv$cvid';
      break;

    case 'MAJOR_TYPE_LIVE_RCMD':
      // live_rcmd.content 是一段被转义的 JSON 字符串，_asMap 会自动解码
      final Map<String, dynamic> rc = _asMap(major['live_rcmd']);
      final Map<String, dynamic> play =
          _asMap(_asMap(rc['content'])['live_play_info']);
      kind = FeedKind.live;
      title = (play['title'] ?? '').toString();
      summary = (play['area_name'] ?? '').toString();
      cover = (play['cover'] ?? '').toString();
      final String roomId = (play['room_id'] ?? '').toString();
      url = roomId.isEmpty ? '' : 'https://live.bilibili.com/$roomId';
      extra['online'] = play['online'];
      break;

    case 'MAJOR_TYPE_LIVE':
      final Map<String, dynamic> l = _asMap(major['live']);
      kind = FeedKind.live;
      title = (l['title'] ?? '').toString();
      summary = (l['area_name'] ?? '').toString();
      cover = (l['cover'] ?? '').toString();
      final String roomId = (l['room_id'] ?? '').toString();
      url = roomId.isEmpty ? '' : 'https://live.bilibili.com/$roomId';
      break;

    case 'MAJOR_TYPE_COMMON':
      final Map<String, dynamic> c = _asMap(major['common']);
      title = (c['title'] ?? '').toString();
      if (summary.isEmpty) summary = (c['desc'] ?? '').toString();
      cover = (c['cover'] ?? '').toString();
      url = _fixJump((c['jump_url'] ?? '').toString());
      break;

    case 'MAJOR_TYPE_MUSIC':
      final Map<String, dynamic> m = _asMap(major['music']);
      title = (m['title'] ?? '').toString();
      url = _fixJump((m['jump_url'] ?? '').toString());
      break;

    case 'MAJOR_TYPE_MEDIALIST':
      final Map<String, dynamic> m = _asMap(major['medialist']);
      title = (m['title'] ?? '').toString();
      cover = (m['cover'] ?? '').toString();
      url = _fixJump((m['jump_url'] ?? '').toString());
      break;

    case 'MAJOR_TYPE_COURSES':
      final Map<String, dynamic> c = _asMap(major['courses']);
      title = (c['title'] ?? '').toString();
      if (summary.isEmpty) summary = (c['desc'] ?? '').toString();
      cover = (c['cover'] ?? '').toString();
      url = _fixJump((c['jump_url'] ?? '').toString());
      break;

    case 'MAJOR_TYPE_UGC_SEASON':
      final Map<String, dynamic> s = _asMap(major['ugc_season']);
      kind = FeedKind.video;
      title = (s['title'] ?? '').toString();
      if (summary.isEmpty) summary = (s['desc'] ?? '').toString();
      cover = (s['cover'] ?? '').toString();
      url = _fixJump((s['jump_url'] ?? '').toString());
      break;

    default:
      // 未知 major：摘要保留 desc.text，类型走 item type 的兜底映射
      break;
  }

  final Object? like = _asMap(modules['module_stat'])['like'];
  if (like is Map && like['count'] is num) {
    extra['like'] = (like['count'] as num).toInt();
  }
  final String tagText =
      (_asMap(modules['module_tag'])['text'] ?? '').toString();
  if (tagText.isNotEmpty) extra['tag'] = tagText;

  return _DynamicBody(
    title: title,
    summary: summary,
    cover: cover,
    url: url,
    kind: kind,
    extra: extra,
  );
}

/// `item.type` → 内容类型的兜底映射（major 能判定时以 major 为准）。
FeedKind _kindFromItemType(String type) {
  switch (type) {
    case 'DYNAMIC_TYPE_AV':
      return FeedKind.video;
    case 'DYNAMIC_TYPE_DRAW':
      return FeedKind.image;
    case 'DYNAMIC_TYPE_WORD':
      return FeedKind.text;
    case 'DYNAMIC_TYPE_FORWARD':
      return FeedKind.repost;
    case 'DYNAMIC_TYPE_ARTICLE':
      return FeedKind.article;
    case 'DYNAMIC_TYPE_LIVE_RCMD':
    case 'DYNAMIC_TYPE_LIVE':
      return FeedKind.live;
    default:
      return FeedKind.unknown;
  }
}

/// `jump_url` 常是协议相对地址（`//www.bilibili.com/...`），补齐协议。
String _fixJump(String url) {
  if (url.isEmpty) return '';
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('/')) return 'https://www.bilibili.com$url';
  return url;
}

/// 摘要统一截断，避免超长图文把本地库撑大、把列表撑爆。
String _clip(String text, {int max = 600}) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…';
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
