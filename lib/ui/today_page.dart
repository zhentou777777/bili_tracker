import 'package:flutter/material.dart';

import '../main.dart';
import '../platform/models.dart';
import '../service/sync_service.dart';
import 'app.dart';
import 'danmaku_page.dart';
import 'external_link.dart';
import 'login_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 今日速览：开播中置顶 + 最近动态倒序。
class TodayPage extends StatefulWidget {
  const TodayPage({super.key});

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  bool _loading = false;
  bool _loggedIn = false;
  List<FeedItem> _items = <FeedItem>[];
  List<LiveStatus> _live = <LiveStatus>[];
  String? _lastReport;

  static const int _days = 3;

  @override
  void initState() {
    super.initState();
    appContext.auth.state.addListener(_onAuthChanged);
    _load();
  }

  @override
  void dispose() {
    appContext.auth.state.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) {
      setState(() => _loggedIn = appContext.auth.state.isLoggedIn('bilibili'));
    }
  }

  Future<void> _load() async {
    _loggedIn = await appContext.auth.isLoggedIn('bilibili');
    final DateTime now = DateTime.now();
    final DateTime from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: _days - 1));

    final List<FeedItem> items = await appContext.db.queryFeeds(
      from: from,
      limit: 300,
    );
    final List<LiveStatus> live = await appContext.db.liveNow();

    if (!mounted) return;
    setState(() {
      _items = items;
      _live = live;
    });
  }

  Future<void> _sync() async {
    if (_loading) return;
    setState(() => _loading = true);

    final SyncService sync = SyncService(appContext);

    // syncAll 内部会先尝试一次「自动追更最近观看直播的已关注主播」
    // （受设置开关与 6 小时冷却约束），因此首次刷新也有机会直接拿到追更名单，
    // 不再需要「先去 UP 主页手动勾选」这一步。
    final SyncReport feeds = await sync.syncAll(foreground: true);
    if (!mounted) return;
    final SyncReport lives = await sync.checkLive();
    if (!mounted) return;

    final int upCount = await appContext.db.upCount();
    await _load();
    if (!mounted) return;

    setState(() {
      _loading = false;
      _lastReport = '${feeds.toString()}｜${lives.toString()}'
          '${feeds.autoTrackSummary == null ? '' : '\n自动追更：${feeds.autoTrackSummary}'}';
    });

    if (feeds.cookieInvalid) {
      _promptRelogin();
      return;
    }
    if (feeds.autoTracked > 0) {
      _toast('自动追更：新增 ${feeds.autoTracked} 位「最近看直播」的已关注主播');
    }
    if (upCount == 0) _promptPickFollows();
  }

  /// 追更名单还是空的时候给一条可点的引导。
  ///
  /// 策略调整（2026-10-02）：不再「首次刷新就把全部关注导入」。关注列表动辄
  /// 几百位，全量导入后每轮抓取要串行请求几百次，耗时长且极易触发风控；
  /// 自动追更（最近观看的直播 ∩ 已关注）能在不导入全量的前提下拿到一份
  /// 可靠的初始名单，剩下的再让用户自己补。
  void _promptPickFollows() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('还没有追更对象：可先去「UP 主」页自动追更，或手动挑几位'),
        action: SnackBarAction(
          label: '去选择',
          onPressed: () =>
              context.findAncestorStateOfType<HomeShellState>()?.goTo(2),
        ),
      ),
    );
  }

  /// 统一的提示入口（判断与使用之间不放 await，避免 context 失效）。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _promptRelogin() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('登录已失效，请重新登录'),
        action: SnackBarAction(
          label: '去登录',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LoginPage()),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;

    return Scaffold(
      appBar: AppBar(
        title: const Text('今日速览'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _sync,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: !_loggedIn
          ? const LoginPrompt(message: '登录后即可聚合你关注的 UP 主最近动态')
          : RefreshIndicator(
              color: c.brand,
              onRefresh: _sync,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 28),
                children: <Widget>[
                  if (_lastReport != null)
                    InfoBar(text: _lastReport!, icon: Icons.insights_rounded),
                  if (_live.isNotEmpty) ...<Widget>[
                    SectionTitle(
                      title: '正在直播',
                      icon: Icons.podcasts_rounded,
                      color: c.live,
                      trailing: TagChip(
                        label: '${_live.length}',
                        color: c.live,
                        dense: true,
                      ),
                    ),
                    ..._live.map(_liveCard),
                  ],
                  SectionTitle(
                    title: '最近 $_days 天',
                    icon: Icons.history_rounded,
                    color: c.brand,
                    trailing: _items.isEmpty
                        ? null
                        : TagChip(
                            label: '${_items.length} 条',
                            color: c.textSecondary,
                            dense: true,
                          ),
                  ),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: EmptyState(
                        icon: Icons.inbox_rounded,
                        title: '还没有抓到动态',
                        description: _live.isEmpty
                            ? '点右上角刷新开始抓取；也可以先去「UP 主」页添加追更对象。'
                            : '点右上角刷新开始抓取。',
                        action: FilledButton.icon(
                          onPressed: _loading ? null : _sync,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('立即刷新'),
                        ),
                      ),
                    )
                  else
                    ..._items.map(_feedCard),
                ],
              ),
            ),
    );
  }

  /// 直播卡片：左侧一条红色竖条，一眼能从动态里区分出来。
  Widget _liveCard(LiveStatus s) => FutureBuilder<UpCreator?>(
        future: appContext.db.up(s.platform, s.upUid),
        builder: (BuildContext context, AsyncSnapshot<UpCreator?> snap) {
          final AppColors c = context.c;
          final String name = snap.data?.name ?? s.upUid;

          return AppCard(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            accent: c.live,
            onTap: () => _open(s.roomId.isEmpty
                ? ''
                : 'https://live.bilibili.com/${s.roomId}'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AvatarBubble(url: snap.data?.face ?? '', size: 42, live: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const TagChip(
                            label: '直播中',
                            icon: Icons.circle,
                            dense: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        s.title.isEmpty ? '直播中' : s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: <Widget>[
                          Icon(Icons.visibility_rounded,
                              size: 12, color: c.textSecondary),
                          const SizedBox(width: 4),
                          Text(
                            '${_formatCount(s.online)} 人在看',
                            style: TextStyle(color: c.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 弹幕姬入口（LAPLACE Chat）。
                //
                // 用独立的图标按钮而不是「长按卡片」：卡片本身的点击是
                // 「进直播间」，两个动作要给两处明确的落点，否则用户根本
                // 不知道还能开弹幕。
                if (s.roomId.isNotEmpty)
                  IconButton(
                    tooltip: '打开弹幕姬',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.forum_outlined, size: 20, color: c.brand),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DanmakuPage(
                          roomId: s.roomId,
                          upName: name,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );

  /// 动态卡片：作者与时间一行，标题独立一行，类型标签在底部。
  ///
  /// 相比原来「作者名和标题挤进同一个 RichText」的排法，
  /// 这种层级更清楚：先看到「谁 · 什么时候」，再看到内容。
  Widget _feedCard(FeedItem it) {
    final AppColors c = context.c;
    final Color kindColor = _kindColor(it.kind);

    return AppCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => _open(it.url),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AvatarBubble(url: it.upFace, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        it.upName.isEmpty ? it.upUid : it.upName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('·',
                        style: TextStyle(color: c.textSecondary, fontSize: 12)),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(it.publishAt),
                      style: TextStyle(color: c.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  it.title.isEmpty ? it.summary : it.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 9),
                Row(
                  children: <Widget>[
                    TagChip(label: feedKindLabel(it.kind), color: kindColor),
                    if (it.summary.isNotEmpty && it.title.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          it.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.textSecondary, fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 类型标签配色。
  ///
  /// 两个注意点：
  /// 1. **不能是 static** —— 颜色来自 `context.c`，而 static 方法拿不到
  ///    State 的 `context`。（阶段 E 把颜色从静态常量搬到主题后，
  ///    原来的 `static Color _kindColor` 会直接编译不过。）
  /// 2. 标签是「同色淡底 + 同色文字」，浅色主题下必须用更深的色，
  ///    否则橙/紫这类亮色在白底上对比度只有 2:1 左右，小字看不清。
  Color _kindColor(FeedKind kind) {
    final AppColors c = context.c;
    final bool light = !c.isDark;

    switch (kind) {
      case FeedKind.video:
        return c.brand;
      case FeedKind.live:
        return c.live;
      case FeedKind.image:
        return light ? const Color(0xFFC26A00) : const Color(0xFFFF9F43);
      case FeedKind.article:
        return light ? const Color(0xFF6A3FD9) : const Color(0xFF9B6BFF);
      case FeedKind.repost:
        return light ? const Color(0xFF5C6779) : const Color(0xFF7A869A);
      default:
        return c.textSecondary;
    }
  }

  static String _formatCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  static String _formatTime(DateTime t) {
    final Duration diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}/${t.month}/${t.day}';
  }

  /// 打开一条内容：优先唤起 B 站 App，不行再走浏览器。
  ///
  /// 以前直接 `launchUrl(https://…)`，系统会用浏览器打开（或弹选择框），
  /// **不会进 B 站 App** —— 用户明确要求「直接跳转 App」，所以改成先试
  /// `bilibili://` 深链（见 external_link.dart）。
  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    if (await openBilibiliContent(url)) return;

    // 两条路都失败（没装 B 站 App 且没有浏览器）：至少别让点击「毫无反应」
    await copyLink(url);
    _toast('没能打开：链接已复制到剪贴板');
  }
}
