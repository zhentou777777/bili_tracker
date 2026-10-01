/// 抓取调度：频率策略、抖动、风控退避、通知分级。
///
/// 一切请求都由客户端直连平台发起；这里产生的「新增条数」只用于本地通知。
library sync_service;

import 'dart:convert';
import 'dart:math';

import '../core/http.dart';
import '../platform/bilibili.dart';
import '../platform/models.dart';
import 'app_context.dart';

/// 一次同步的结果。
class SyncReport {
  SyncReport();

  int newFeeds = 0;
  int newLive = 0;

  /// Cookie 失效，UI 应引导重新登录。
  bool cookieInvalid = false;

  /// 触发风控，本轮提前结束。
  bool riskControl = false;

  final List<String> messages = <String>[];

  bool get hasError => messages.isNotEmpty;

  void log(String msg) => messages.add(msg);

  @override
  String toString() => '新动态 $newFeeds · 新开播 $newLive'
      '${cookieInvalid ? ' · Cookie 已失效' : ''}'
      '${riskControl ? ' · 触发风控已降速' : ''}';
}

/// 关注列表的一次**只读**抓取结果。
///
/// 注意：这里不写数据库。关注列表动辄几百位，若自动全量导入，
/// 后续每一轮抓取都会变成几百次串行请求（几十分钟，且极易触发风控）；
/// 因此策略调整为「拉全量 → 用户勾选 → 只导入选中的」。
class FollowListResult {
  FollowListResult();

  /// 抓到的全部关注（按接口顺序：最近关注在前）。
  final List<UpCreator> ups = <UpCreator>[];

  /// 接口返回的关注总数；取不到时为 -1。
  int total = -1;

  /// Cookie 失效，UI 应引导重新登录。
  bool cookieInvalid = false;

  /// 触发风控，本轮提前结束。
  bool riskControl = false;

  /// 本结果来自本地缓存时的抓取时间（实时抓取为 null）。
  DateTime? cachedAt;

  final List<String> messages = <String>[];

  bool get hasError => messages.isNotEmpty;

  String get summary => total > 0
      ? '已获取 ${ups.length} / 共 $total 位关注'
      : '已获取 ${ups.length} 位关注';
}

class SyncService {
  SyncService(this._ctx);

  final AppContext _ctx;
  final Random _rnd = Random();

  /// 各档位的目标间隔。
  static const Map<String, Duration> kIntervals = <String, Duration>{
    'high': Duration(minutes: 8),
    'medium': Duration(minutes: 20),
    'low': Duration(hours: 24),
  };

  /// 抓取**完整关注列表**（分页，只读，不写库）。
  ///
  /// 与旧版「拉取即全量导入」的区别：旧版抓到什么就全部写进数据库（等于自动
  /// 追更全部关注），新版只把列表交给界面展示，导入哪些由用户勾选决定。
  ///
  /// - [onProgress] 每拿到一页回调一次（已获取条数 / 总数），用于界面进度条。
  /// - [maxPages] 兜底上限，避免异常账号无限翻页。
  Future<FollowListResult> fetchFollowings({
    void Function(int got, int total)? onProgress,
    int maxPages = 40,
  }) async {
    final FollowListResult result = FollowListResult();
    final BilibiliAdapter? adapter = _ctx.bilibiliAdapter();
    if (adapter == null) {
      result.messages.add('未找到 B 站规则，请更新规则文件');
      return result;
    }
    final String? selfUid = await _ctx.auth.selfUid('bilibili');
    if (selfUid == null || selfUid.isEmpty) {
      result.cookieInvalid = true;
      result.messages.add('未登录或登录信息不完整');
      return result;
    }

    try {
      final Set<String> seen = <String>{};
      for (int page = 1; page <= maxPages; page++) {
        final FollowPage fp =
            await adapter.fetchFollowingsPage(selfUid: selfUid, page: page);
        if (fp.total > 0) result.total = fp.total;
        for (final UpCreator up in fp.items) {
          if (up.uid.isEmpty || !seen.add(up.uid)) continue;
          result.ups.add(up);
        }
        onProgress?.call(result.ups.length, result.total);

        if (fp.items.isEmpty || !fp.hasMore) break;
        // 总数已知且已抓满，不必再多发一次请求
        if (result.total > 0 && result.ups.length >= result.total) break;
        await _gap();
      }
      if (result.ups.isEmpty) result.messages.add('关注列表为空');
    } on ApiException catch (e) {
      _handleFollowApiError(e, result);
    } catch (e) {
      result.messages.add('拉取关注列表失败：$e');
    }
    return result;
  }

  /// 缓存键：关注列表整表（几百条 JSON，缓存后可秒开，避免每次重拉）。
  static const String _kFollowCacheKey = 'follow_cache_v1';

  /// 把抓到的关注列表写入本地缓存。
  Future<void> cacheFollowings(FollowListResult result) async {
    if (result.ups.isEmpty) return;
    await _ctx.db.setSetting(
      _kFollowCacheKey,
      jsonEncode(<String, dynamic>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'total': result.total,
        'ups': <Map<String, dynamic>>[
          for (final UpCreator up in result.ups) up.toJson(),
        ],
      }),
    );
  }

  /// 读取上次缓存的关注列表；没有缓存时返回 null。
  Future<FollowListResult?> loadCachedFollowings() async {
    final String? raw = await _ctx.db.getSetting(_kFollowCacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);

      // 用 cast 显式取列表，避免依赖类型提升的细节
      final Object? rawList = m['ups'];
      final List<Object?> entries =
          rawList is List ? rawList.cast<Object?>() : const <Object?>[];
      if (entries.isEmpty) return null;

      final FollowListResult result = FollowListResult();
      result.total = m['total'] is num ? (m['total'] as num).toInt() : -1;
      result.cachedAt = m['at'] is num
          ? DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt())
          : null;
      for (final Object? entry in entries) {
        if (entry is! Map) continue;
        final UpCreator up = UpCreator.fromJson(Map<String, dynamic>.from(entry));
        if (up.uid.isNotEmpty) result.ups.add(up);
      }
      return result.ups.isEmpty ? null : result;
    } catch (_) {
      // 缓存格式失效就当作没有缓存，下一次实时抓取会覆盖它
      return null;
    }
  }

  /// 已追更 UP 的 key 集合（`platform:uid`），供选择页标记「已追更」。
  Future<Set<String>> trackedKeys() async {
    final List<UpCreator> ups = await _ctx.db.allUps();
    return <String>{for (final UpCreator up in ups) up.key};
  }

  /// 只导入用户勾选的 UP 主（已有的个性化配置不会被覆盖）。
  Future<int> importSelected(List<UpCreator> ups) => _ctx.db.upsertUps(ups);

  /// 按频率策略抓取所有 UP 主的动态与投稿。
  Future<SyncReport> syncAll({bool foreground = true}) async {
    final SyncReport report = SyncReport();
    final BilibiliAdapter? adapter = _ctx.bilibiliAdapter();
    if (adapter == null) {
      report.log('未找到 B 站规则');
      return report;
    }

    if (await _ctx.auth.isMarkedInvalid('bilibili')) {
      report.cookieInvalid = true;
      return report;
    }

    final List<UpCreator> ups = await _ctx.db.allUps();
    if (ups.isEmpty) {
      report.log('还没有订阅任何 UP 主');
      return report;
    }

    for (final UpCreator up in ups) {
      if (!shouldSync(up, foreground: foreground)) continue;

      // 抖动：避免整批请求在同一秒发出
      await Future<void>.delayed(
          Duration(milliseconds: 300 + _rnd.nextInt(1200)));

      try {
        report.newFeeds += await _syncOneUp(adapter, up);
        await _ctx.db.markSynced(up.platform, up.uid, DateTime.now());
      } on ApiException catch (e) {
        _handleApiError(e, report);
        if (report.cookieInvalid || report.riskControl) break;
      } catch (e) {
        report.log('${up.name} 抓取失败：$e');
      }

      await _gap();
    }

    await _dispatchFeedNotifications();
    return report;
  }

  /// 直播状态轮询（公开接口，不依赖 Cookie）。
  Future<SyncReport> checkLive() async {
    final SyncReport report = SyncReport();
    final BilibiliAdapter? adapter = _ctx.bilibiliAdapter();
    if (adapter == null) {
      report.log('未找到 B 站规则');
      return report;
    }

    final List<String> uids = await _ctx.db.upsWithLiveEnabled();
    if (uids.isEmpty) return report;

    try {
      final List<LiveStatus> statuses = await adapter.fetchLiveStatus(uids);
      for (final LiveStatus s in statuses) {
        final bool justStarted = await _ctx.db.saveLiveState(s);
        if (justStarted) report.newLive++;

        if (!s.isLive) continue;

        // 延迟推送：开播后 X 分钟再打扰用户
        final UpCreator? up = await _ctx.db.up(s.platform, s.upUid);
        final int delayMinutes = up?.liveDelayMinutes ?? 0;
        final DateTime start = s.startedAt ?? DateTime.now();
        final bool delayElapsed =
            DateTime.now().difference(start).inMinutes >= delayMinutes;

        final bool alreadyNotified =
            await _ctx.db.isLiveNotified(s.platform, s.upUid);
        if (!alreadyNotified && delayElapsed) {
          await _ctx.notify.notifyLive(
            upName: up?.name ?? s.uname,
            roomTitle: s.title,
            roomUrl:
                s.roomId.isEmpty ? '' : 'https://live.bilibili.com/${s.roomId}',
          );
          await _ctx.db.markLiveNotified(s.platform, s.upUid);
        }
      }
    } on ApiException catch (e) {
      // 直播接口是公开的，一般不会因为登录态失败
      report.log('直播状态检查失败：${e.code}');
    } catch (e) {
      report.log('直播状态检查失败：$e');
    }
    return report;
  }

  /// 手动添加 UP 主：按 UID 或主页链接补全资料。
  Future<UpCreator?> addUpByInput(String input) async {
    final BilibiliAdapter? adapter = _ctx.bilibiliAdapter();
    if (adapter == null) return null;

    final String? uid = _extractUid(input);
    if (uid == null) return null;

    final UpCreator? existing = await _ctx.db.up('bilibili', uid);
    if (existing != null) return existing;

    final UpCreator? info = await adapter.fetchUserInfo(uid);
    if (info == null) return null;
    await _ctx.db.upsertUp(info);
    return info;
  }

  /// 判断某 UP 主当前是否该抓。
  ///
  /// 活跃度自动降级：7 天内有更新按用户档位，7–30 天降一档，超过 30 天每天一次。
  bool shouldSync(UpCreator up, {bool foreground = true}) {
    final DateTime? last = up.lastSyncAt;
    if (last == null) return true;

    final Duration interval = effectiveInterval(up);
    final DateTime now = DateTime.now();
    if (foreground) {
      return now.difference(last) >= interval;
    }
    // 后台放宽到至少 15 分钟，避免系统判定为滥用
    final Duration backoff = interval < const Duration(minutes: 15)
        ? const Duration(minutes: 15)
        : interval;
    return now.difference(last) >= backoff;
  }

  /// 结合用户配置与真实活跃度算出实际间隔。
  Duration effectiveInterval(UpCreator up) {
    final DateTime? published = up.lastPublishAt;
    final int idleDays =
        published == null ? 999 : DateTime.now().difference(published).inDays;

    String tier = up.frequency.name;
    if (idleDays > 30) {
      tier = 'low';
    } else if (idleDays > 7) {
      tier = tier == 'high'
          ? 'medium'
          : tier == 'medium'
              ? 'low'
              : 'low';
    }
    return kIntervals[tier] ?? const Duration(minutes: 20);
  }

  // ---------------- 内部 ----------------

  Future<int> _syncOneUp(BilibiliAdapter adapter, UpCreator up) async {
    final List<FeedItem> all = <FeedItem>[];

    // 动态
    try {
      final DynamicPage page = await adapter.fetchDynamics(uid: up.uid);
      all.addAll(page.items);
    } on ApiException {
      rethrow;
    }

    await _gap();

    // 投稿（视频）—— 需要 WBI 签名，失败不阻断动态结果
    try {
      final List<FeedItem> videos = await adapter.fetchVideos(uid: up.uid);
      all.addAll(videos);
    } on ApiException catch (e) {
      // 投稿接口更容易触发风控，动态拿到就够用
      if (!e.isNotLogin) {
        // 忽略，继续写入已有结果
      } else {
        rethrow;
      }
    }

    if (all.isEmpty) return 0;

    final int inserted = await _ctx.db.insertFeeds(all);

    // 更新最近发布时间，供频率策略使用
    DateTime? latest = up.lastPublishAt;
    for (final FeedItem it in all) {
      if (latest == null || it.publishAt.isAfter(latest)) latest = it.publishAt;
    }
    if (latest != null) {
      await _ctx.db.touchUpPublish(up.platform, up.uid, latest);
    }
    return inserted;
  }

  /// 通知分级：核心分组单条即时，其余按批汇总，静默组只进日历。
  Future<void> _dispatchFeedNotifications() async {
    final List<FeedItem> pending = await _ctx.db.queryFeeds(
      onlyNotNotified: true,
      limit: 100,
    );
    if (pending.isEmpty) return;

    final List<FeedItem> toNotify = <FeedItem>[];
    final List<FeedItem> silent = <FeedItem>[];
    final Set<String> coreUids = <String>{};

    final List<UpCreator> ups = await _ctx.db.allUps();
    for (final UpCreator up in ups) {
      if (up.group == '核心关注' || up.group == '直播优先') {
        coreUids.add(up.uid);
      }
    }

    for (final FeedItem it in pending) {
      final UpCreator? up = await _ctx.db.up(it.platform, it.upUid);
      final bool pushEnabled = up?.pushDynamic ?? true;
      final bool isCore = coreUids.contains(it.upUid);

      if (!pushEnabled) {
        silent.add(it);
        continue;
      }
      if (isCore) {
        await _ctx.notify.notifyFeed(
          upName: it.upName,
          kind: it.kind,
          content: it.title.isEmpty ? it.summary : it.title,
          url: it.url,
        );
        toNotify.add(it);
      } else {
        toNotify.add(it);
      }
    }

    // 非核心的走汇总
    final List<FeedItem> summaryItems =
        toNotify.where((FeedItem it) => !coreUids.contains(it.upUid)).toList();
    if (summaryItems.isNotEmpty) {
      final Set<String> upsInSummary = <String>{
        for (final FeedItem it in summaryItems) it.upUid,
      };
      await _ctx.notify.notifySummary(
        upCount: upsInSummary.length,
        itemCount: summaryItems.length,
      );
    }

    // 全部标记已通知（静默的也标记，避免下次重复计算）
    await _ctx.db.markNotified(<FeedItem>[...toNotify, ...silent]);
  }

  void _handleApiError(ApiException e, SyncReport report) {
    final ({String message, bool cookieInvalid, bool riskControl}) c =
        _classifyApiError(e);
    report.cookieInvalid = c.cookieInvalid;
    report.riskControl = c.riskControl;
    if (c.cookieInvalid) _ctx.auth.markInvalid('bilibili');
    report.log(c.message);
  }

  void _handleFollowApiError(ApiException e, FollowListResult result) {
    final ({String message, bool cookieInvalid, bool riskControl}) c =
        _classifyApiError(e);
    result.cookieInvalid = c.cookieInvalid;
    result.riskControl = c.riskControl;
    if (c.cookieInvalid) _ctx.auth.markInvalid('bilibili');
    result.messages.add(c.message);
  }

  /// 把接口异常归类成用户可见的提示（两个报告类共用，避免两处漂移）。
  ({String message, bool cookieInvalid, bool riskControl}) _classifyApiError(
    ApiException e,
  ) {
    if (e.isNotLogin) {
      return (
        message: 'Cookie 已失效，请重新登录',
        cookieInvalid: true,
        riskControl: false,
      );
    }
    if (e.isRiskControl) {
      return (
        message: '触发风控（${e.code}），已停止本轮抓取并降速',
        cookieInvalid: false,
        riskControl: true,
      );
    }
    if (e.isBadSign) {
      return (
        message: '签名校验失败（${e.code}），WBI 密钥可能已过期',
        cookieInvalid: false,
        riskControl: false,
      );
    }
    return (
      message: '接口错误 ${e.code}：${e.message}',
      cookieInvalid: false,
      riskControl: false,
    );
  }

  /// 请求之间的间隔，避免短时间高频。
  Future<void> _gap() =>
      Future<void>.delayed(Duration(milliseconds: 800 + _rnd.nextInt(1500)));

  /// 从 UID / space 链接 / b23 短链中提取 UID。
  static String? _extractUid(String input) {
    final String s = input.trim();
    if (RegExp(r'^\d+$').hasMatch(s)) return s;
    final RegExpMatch? m = RegExp(r'space\.bilibili\.com/(\d+)').firstMatch(s);
    if (m != null) return m.group(1);
    final RegExpMatch? m2 = RegExp(r'uid=(\d+)').firstMatch(s);
    return m2?.group(1);
  }
}
