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
