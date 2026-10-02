/// 本地通知。
///
/// 第一阶段全部走本地通知：检测在客户端，通知也在客户端，服务端不参与。
/// 分级策略：
///   - 开播 / 核心 UP 主 → 即时单条
///   - 普通更新 → 汇总成「3 位 UP 主更新了 5 条」
///   - 静默档 → 只进日历，不打扰
library notify_service;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/text.dart';

import '../platform/models.dart';

class NotifyService {
  NotifyService(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const String _channelLive = 'live_channel';
  static const String _channelFeed = 'feed_channel';
  static const String _channelSummary = 'summary_channel';

  bool _initialized = false;

  Future<bool> init() async {
    if (_initialized) return true;
    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings ios = DarwinInitializationSettings();
    const InitializationSettings settings =
        InitializationSettings(android: android, iOS: ios);

    final bool? ok = await _plugin.initialize(settings);
    _initialized = ok ?? false;

    final AndroidFlutterLocalNotificationsPlugin? androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // 开播用最高优先级，其它走默认 / 低优先级
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelLive,
        '开播提醒',
        description: '关注的 UP 主开播时立即通知',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelFeed,
        '动态更新',
        description: '核心关注的 UP 主发布新内容时通知',
        importance: Importance.defaultImportance,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelSummary,
        '更新汇总',
        description: '按批次汇总的更新提醒',
        importance: Importance.low,
      ),
    );

    return _initialized;
  }

  /// 申请通知权限。
  ///
  /// 两端机制不同，必须分别处理：
  /// - **Android 13+**：需要显式调用 `requestNotificationsPermission()`，否则通知静默不显示；
  /// - **iOS / macOS**：权限在 `initialize()` 时由系统弹窗申请，之后可用
  ///   `checkPermissions()` 查询。
  ///
  /// ⚠️ **iOS 分支从未在真机验证过**（第一阶段只在 Android 上规划验证，见交接文档
  /// 「已知限制」）。这里把 iOS 的查询补上，但**不声称它可用**：返回值只代表
  /// 「系统当前是否已授权」，不保证通知能正常送达。真要上 iOS，需要一台真机过一遍。
  Future<bool> requestPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      final bool? granted = await androidImpl.requestNotificationsPermission();
      return granted ?? true;
    }

    // 非 Android（当前只有 iOS 有实现）：权限在 initialize() 时由系统弹窗申请，
    // 这里只查询当前授权状态，**不重复申请**。
    final IOSFlutterLocalNotificationsPlugin? iosImpl =
        _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (iosImpl != null) {
      final NotificationsEnabledOptions? opts = await iosImpl.checkPermissions();
      return opts?.isEnabled ?? true;
    }
    return true;
  }

  Future<void> notifyLive({
    required String upName,
    required String roomTitle,
    required String roomUrl,
  }) async {
    await _show(
      id: _nextId(),
      channelId: _channelLive,
      title: '🔴 $upName 开播了',
      body: roomTitle.isEmpty ? '点击前往直播间' : roomTitle,
      payload: roomUrl,
      ongoing: false,
    );
  }

  Future<void> notifyFeed({
    required String upName,
    required FeedKind kind,
    required String content,
    required String url,
  }) async {
    final String label = feedKindLabel(kind);
    await _show(
      id: _nextId(),
      channelId: _channelFeed,
      title: '$upName 发布了新$label',
      body: content.isEmpty ? '点击查看' : _clip(content),
      payload: url,
    );
  }

  /// 汇总推送：多条更新合成一条，避免通知栏被刷屏。
  Future<void> notifySummary({
    required int upCount,
    required int itemCount,
  }) async {
    await _show(
      id: _nextId(),
      channelId: _channelSummary,
      title: '$upCount 位 UP 主更新了 $itemCount 条动态',
      body: '打开追更台查看今日更新',
      payload: 'summary',
    );
  }

  Future<void> _show({
    required int id,
    required String channelId,
    required String title,
    required String body,
    String? payload,
    bool ongoing = false,
  }) async {
    if (!_initialized) await init();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          _channelName(channelId),
          importance: channelId == _channelLive
              ? Importance.max
              : Importance.defaultImportance,
          priority: channelId == _channelLive
              ? Priority.max
              : Priority.defaultPriority,
          ongoing: ongoing,
          autoCancel: true,
        ),
        iOS: const DarwinNotificationDetails(presentSound: true),
      ),
      payload: payload,
    );
  }

  static String _channelName(String id) {
    switch (id) {
      case _channelLive:
        return '开播提醒';
      case _channelFeed:
        return '动态更新';
      default:
        return '更新汇总';
    }
  }

  static String _clip(String s) => clipText(s, max: 60);

  /// 通知 id 用自增计数器，不用随机数。
  ///
  /// 原来是 `100000 + Random().nextInt(899999)`：虽然撞上的概率不高，
  /// 但一旦两条通知拿到同一个 id，后一条会**覆盖**前一条，症状是「少了一条提醒」
  /// 且完全无迹可寻。自增不会有这个问题，环形回绕保持在 6 位范围内。
  static int _seqId = 100000;

  static int _nextId() {
    _seqId = _seqId >= 999999 ? 100000 : _seqId + 1;
    return _seqId;
  }
}
