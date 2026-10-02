/// 跨平台的领域模型，纯 Dart，不绑定任何存储或 UI 框架。
library models;

/// 内容类型。
enum FeedKind { video, image, text, repost, article, live, unknown }

FeedKind feedKindFromName(String? name) {
  switch (name) {
    case 'video':
      return FeedKind.video;
    case 'image':
      return FeedKind.image;
    case 'text':
      return FeedKind.text;
    case 'repost':
      return FeedKind.repost;
    case 'article':
      return FeedKind.article;
    case 'live':
      return FeedKind.live;
    default:
      return FeedKind.unknown;
  }
}

String feedKindLabel(FeedKind kind) {
  switch (kind) {
    case FeedKind.video:
      return '视频';
    case FeedKind.image:
      return '图文';
    case FeedKind.text:
      return '文字';
    case FeedKind.repost:
      return '转发';
    case FeedKind.article:
      return '专栏';
    case FeedKind.live:
      return '直播';
    case FeedKind.unknown:
      return '动态';
  }
}

/// 抓取频率档位，按 UP 主活跃度自动调整。
enum FetchFrequency { high, medium, low }

FetchFrequency fetchFrequencyFromName(String? name) {
  switch (name) {
    case 'high':
      return FetchFrequency.high;
    case 'low':
      return FetchFrequency.low;
    default:
      return FetchFrequency.medium;
  }
}

/// 订阅的 UP 主 / 博主。
class UpCreator {
  UpCreator({
    required this.platform,
    required this.uid,
    required this.name,
    this.face = '',
    this.sign = '',
    this.group = 'default',
    this.frequency = FetchFrequency.medium,
    this.pushDynamic = true,
    this.pushLive = true,
    this.showInCalendar = true,
    this.liveDelayMinutes = 0,
    this.lastPublishAt,
    this.lastSyncAt,
    this.followedAt,
  });

  final String platform; // bilibili / weibo
  final String uid;
  String name;
  String face;
  String sign;

  /// 分组名：核心关注 / 普通关注 / 直播优先 ...
  String group;
  FetchFrequency frequency;
  bool pushDynamic;
  bool pushLive;
  bool showInCalendar;

  /// 开播后延迟 N 分钟再推送，避免刚开播的瞬时打扰。
  int liveDelayMinutes;

  DateTime? lastPublishAt;

  /// 上次成功抓取的时间，供频率策略使用。
  DateTime? lastSyncAt;

  DateTime? followedAt;

  /// 全局唯一键：同一 UID 在不同平台可共存。
  String get key => '$platform:$uid';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'uid': uid,
        'name': name,
        'face': face,
        'sign': sign,
        'group': group,
        'frequency': frequency.name,
        'push_dynamic': pushDynamic,
        'push_live': pushLive,
        'show_in_calendar': showInCalendar,
        'live_delay_minutes': liveDelayMinutes,
        'last_publish_at': lastPublishAt?.millisecondsSinceEpoch,
        'followed_at': followedAt?.millisecondsSinceEpoch,
      };

  factory UpCreator.fromJson(Map<String, dynamic> json) => UpCreator(
        platform: json['platform']?.toString() ?? '',
        uid: json['uid']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        face: json['face']?.toString() ?? '',
        sign: json['sign']?.toString() ?? '',
        group: json['group']?.toString() ?? 'default',
        frequency: fetchFrequencyFromName(json['frequency']?.toString()),
        pushDynamic: json['push_dynamic'] != false,
        pushLive: json['push_live'] != false,
        showInCalendar: json['show_in_calendar'] != false,
        liveDelayMinutes: json['live_delay_minutes'] is int
            ? json['live_delay_minutes'] as int
            : 0,
        lastPublishAt: json['last_publish_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['last_publish_at'] as int)
            : null,
        followedAt: json['followed_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['followed_at'] as int)
            : null,
      );
}

/// 一条动态 / 投稿。
class FeedItem {
  FeedItem({
    required this.platform,
    required this.upUid,
    required this.itemId,
    required this.kind,
    required this.publishAt,
    this.upName = '',
    this.upFace = '',
    this.title = '',
    this.summary = '',
    this.cover = '',
    this.url = '',
    this.extra,
  });

  final String platform;
  final String upUid;
  final String itemId;
  final FeedKind kind;
  final DateTime publishAt;

  String upName;
  String upFace;
  String title;
  String summary;
  String cover;
  String url;

  /// 播放量、时长等附加信息，直接进详情展示。
  final Map<String, dynamic>? extra;

  /// 去重键：用于本地库判重与增量抓取。
  String get key => '$platform:$upUid:$itemId';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'up_uid': upUid,
        'item_id': itemId,
        'kind': kind.name,
        'publish_at': publishAt.millisecondsSinceEpoch,
        'up_name': upName,
        'up_face': upFace,
        'title': title,
        'summary': summary,
        'cover': cover,
        'url': url,
      };
}

/// 直播状态快照。
class LiveStatus {
  LiveStatus({
    required this.platform,
    required this.upUid,
    required this.roomId,
    required this.isLive,
    this.title = '',
    this.uname = '',
    this.online = 0,
    this.cover = '',
    this.startedAt,
  });

  final String platform;
  final String upUid;
  final String roomId;
  final bool isLive;
  final String title;
  final String uname;
  final int online;
  final String cover;
  final DateTime? startedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'up_uid': upUid,
        'room_id': roomId,
        'is_live': isLive,
        'title': title,
        'uname': uname,
        'online': online,
        'started_at': startedAt?.millisecondsSinceEpoch,
      };
}

/// 一条「最近观看的直播」记录（来自 B 站观看历史，`history/cursor?type=live`）。
///
/// 用于「自动追更最近观看直播的已关注主播」：把这里的 uid 和关注列表求交集，
/// 命中的就是「关注了、而且最近真的点进去看过直播」的主播。
class WatchedLive {
  WatchedLive({
    required this.uid,
    this.name = '',
    this.face = '',
    this.roomId = '',
    this.title = '',
    this.cover = '',
    this.viewedAt,
  });

  /// 主播 UID（历史记录的 `author_mid`）。
  final String uid;
  final String name;
  final String face;
  final String roomId;
  final String title;
  final String cover;
  final DateTime? viewedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'uid': uid,
        'name': name,
        'face': face,
        'room_id': roomId,
        'title': title,
        'cover': cover,
        'viewed_at': viewedAt?.millisecondsSinceEpoch,
      };
}

/// 一次完成的直播场次（用于日历标记）。
class LiveSession {
  LiveSession({
    required this.platform,
    required this.upUid,
    required this.roomId,
    required this.startedAt,
    this.title = '',
    this.endedAt,
    this.peakOnline = 0,
  });

  final String platform;
  final String upUid;
  final String roomId;
  final DateTime startedAt;
  final String title;
  final DateTime? endedAt;
  final int peakOnline;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'up_uid': upUid,
        'room_id': roomId,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'title': title,
        'peak_online': peakOnline,
      };
}

/// 扫码登录状态。
///
/// 语义名与规则文件 `login.status_map` 的取值一一对应，
/// 状态码本身不写死在代码里 —— 它属于「接口随时会变」的那一类。
enum LoginQrStatus {
  /// 86101 还没人扫
  waiting,

  /// 86090 已扫码，等 App 里点「确认」
  scanned,

  /// 86038 二维码超时（B 站是 180 秒），必须重新申请
  expired,

  /// 0 已确认，Cookie 已下发
  success,

  /// 规则表里没登记的码，保持原样不猜
  unknown,
}

/// 申请到的一次登录二维码。
class LoginQrSession {
  const LoginQrSession({required this.qrcodeKey, required this.url});

  final String qrcodeKey;

  /// 二维码内容，同时也是「同设备跳转授权」的目标地址
  /// （`account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=...`）。
  ///
  /// 手机上装了 B 站 App 时，用系统打开这个地址会被 App Links 接管、
  /// 直接唤起 B 站 App 的授权确认页 —— 用户点一下「确认」即可，
  /// 不需要第二台设备来扫码。
  final String url;

  bool get isValid => qrcodeKey.isNotEmpty && url.isNotEmpty;
}

/// 一次轮询的结果。
class LoginPollResult {
  const LoginPollResult({
    required this.status,
    this.message = '',
    this.crossDomainUrl = '',
    this.cookies = const <String, String>{},
  });

  final LoginQrStatus status;

  /// 接口返回的原始状态文案（如「未扫码」），用于界面兜底显示。
  final String message;

  /// 登录成功时的跨域回调地址。
  ///
  /// **它不是「带 Cookie 的链接」**：直接 GET 它才会在 302 响应头里下发
  /// SESSDATA 等 Cookie，且必须带 Referer、必须禁止自动跟随重定向。
  final String crossDomainUrl;

  /// `status == success` 时解析出的 Cookie（含 HttpOnly 的 SESSDATA）。
  final Map<String, String> cookies;

  bool get isSuccess => status == LoginQrStatus.success;

  /// 成功但没拿到 Cookie —— 属于「看起来成功、实际登不上」的坏状态，
  /// 上层必须显式报错，不能静默当成登录完成。
  bool get isSuccessWithoutCookie => isSuccess && cookies.isEmpty;
}
