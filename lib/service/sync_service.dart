/// 抓取调度：频率策略、抖动、风控退避、通知分级。
///
/// 一切请求都由客户端直连平台发起；这里产生的「新增条数」只用于本地通知。
library sync_service;

import 'dart:math';

import '../core/http.dart';
import '../data/db.dart';
import '../platform/bilibili.dart';
import '../platform/models.dart';
import 'app_context.dart';

/// 一次同步的结果。
class SyncReport {
  SyncReport();

  int importedUps = 0;
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
  String toString() => '新动态 $newFeeds · 新开播 $newLive · 导入 $importedUps'
      '${cookieInvalid ? ' · Cookie 已失效' : ''}'
      '${riskControl ? ' · 触发风控已降速' : ''}';
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

  /// 拉取关注列表。已有 UP 只更新资料，不动用户配置。
  Future<SyncReport> syncFollowings() async {
    final SyncReport report = SyncReport();
    final BilibiliAdapter? adapter = _ctx.bilibiliAdapter();
    if (adapter == null) {
      report.log('未找到 B 站规则，请更新规则文件');
      return report;
    }
    final String? selfUid = await _ctx.auth.selfUid('bilibili');
    if (selfUid == null || selfUid.isEmpty) {
      report.cookieInvalid = true;
      report.log('未登录或登录信息不完整');
      return report;
    }

    try {
      final List<UpCreator> collected = <UpCreator>[];
      for (int page = 1; page <= 20; page++) {
        final List<UpCreator> batch =
            await adapter.fetchFollowings(selfUid: selfUid, page: page);
        if (batch.isEmpty) break;
        collected.addAll(batch);
        if (batch.length < 50) break;
        await _gap();
      }
      await _ctx.db.upsertUps(collected);
      report.importedUps = collected.length;
      if (collected.isEmpty) report.log('关注列表为空');
    } on ApiException catch (e) {
      _handleApiError(e, report);
    } catch (e) {
      report.log('拉取关注列表失败：$e');
    }
    return report;
  }

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
    if (e.isNotLogin) {
      report.cookieInvalid = true;
      report.log('Cookie 已失效，请重新登录');
      _ctx.auth.markInvalid('bilibili');
      return;
    }
    if (e.isRiskControl) {
      report.riskControl = true;
      report.log('触发风控（${e.code}），已停止本轮抓取并降速');
      return;
    }
    if (e.isBadSign) {
      report.log('签名校验失败（${e.code}），WBI 密钥可能已过期');
      return;
    }
    report.log('接口错误 ${e.code}：${e.message}');
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
