/// 弹幕姬（LAPLACE Chat，`chat.vrp.moe`）的地址规则。
///
/// 单独放一个**不依赖 Flutter** 的文件，理由和 `core/text.dart` 一样：
/// 纯逻辑要能被离线单元测试直接跑，不必启动 widget 树。
///
/// 背景：该站给每个直播间一个固定页面 `/dashboard/{房间号}`，但
/// **未登记 / 不存在的房间会被对端甩回站点首页 `/`** —— 用户看到的现象就是
/// 「打开的是弹幕姬，可是跟我的直播间对不上」。所以页面加载后必须核对 URL。
///
/// 一条克制的设计原则：**只对「被甩到首页」这一种实测到的症状下判断**，
/// 其余地址（登录页、站内跳转、外链）一律按正常页面显示。原因是判定过宽
/// 会把正常的登录流程挡在外面，反而制造新问题。
library danmaku_link;

/// 该站的域名。
const String kDanmakuHost = 'chat.vrp.moe';

/// 直播间页面的路径前缀。
const String kDanmakuDashboardPrefix = '/dashboard/';

/// 一个地址相对于「弹幕姬直播间页面」的分类。
enum DanmakuUrlKind {
  /// 正是这个直播间的弹幕机页面 —— 正常。
  room,

  /// 被甩到了站点首页（`chat.vrp.moe/`）—— 实测的「对不上直播间」。
  home,

  /// 其它地址：登录页、站内路由、外链、空值等。
  /// **不武断判死**，按正常页面显示。
  other,
}

/// 判断一个地址属于哪一类。
///
/// 两个刻意的严格之处：
/// 1. `room` 也要求域名是本站在用 —— 否则 `example.com/dashboard/1`
///    会被误判成「对上了」；
/// 2. 光有前缀不算数：`/dashboard/`（没有房间号）打开的是空壳页，
///    与跳首页同属「对不上」。
DanmakuUrlKind classifyDanmakuUrl(String? raw) {
  if (raw == null || raw.isEmpty) return DanmakuUrlKind.other;

  final Uri? uri = Uri.tryParse(raw);
  if (uri == null) return DanmakuUrlKind.other;

  final bool onSite = uri.host.toLowerCase() == kDanmakuHost;
  if (!onSite) return DanmakuUrlKind.other;

  final String path = uri.path;
  final bool hasRoomId = path.startsWith(kDanmakuDashboardPrefix) &&
      path.length > kDanmakuDashboardPrefix.length;
  if (hasRoomId) return DanmakuUrlKind.room;

  if (path.isEmpty || path == '/') return DanmakuUrlKind.home;

  return DanmakuUrlKind.other;
}

/// 把地址缩成便于阅读的形式：首页只显示域名，其余显示「域名 + 路径」。
///
/// 用途是把「被跳转到了哪里」如实告诉用户 —— 只写「打不开」等于没说。
String danmakuUrlDisplay(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw;
  if (uri.path.isEmpty || uri.path == '/') return uri.host;
  return '${uri.host}${uri.path}';
}
