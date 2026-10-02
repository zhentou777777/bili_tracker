import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../platform/models.dart';
import '../service/sync_service.dart';
import 'app.dart';
import 'login_page.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日速览'),
        actions: <Widget>[
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _sync,
          ),
        ],
      ),
      body: !_loggedIn
          ? const LoginPrompt(message: '登录后即可聚合你关注的 UP 主最近动态')
          : RefreshIndicator(
              onRefresh: _sync,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: <Widget>[
                  if (_lastReport != null) _reportBar(_lastReport!),
                  if (_live.isNotEmpty) ...<Widget>[
                    _sectionTitle('正在直播', TrackerTheme.live, Icons.circle),
                    ..._live.map(_liveCard),
                  ],
                  _sectionTitle(
                      '最近 $_days 天', TrackerTheme.brand, Icons.history),
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          '还没有抓取到动态，点右上角刷新试试',
                          style: TextStyle(color: TrackerTheme.textSecondary),
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

  Widget _reportBar(String text) => Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: TrackerTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TrackerTheme.border),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.info_outline,
                size: 14, color: TrackerTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                    color: TrackerTheme.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  Widget _sectionTitle(String text, Color color, IconData icon) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );

  Widget _liveCard(LiveStatus s) => FutureBuilder<UpCreator?>(
        future: appContext.db.up(s.platform, s.upUid),
        builder: (BuildContext context, AsyncSnapshot<UpCreator?> snap) {
          final String name = snap.data?.name ?? s.upUid;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              dense: true,
              leading: _avatar(snap.data?.face ?? '', live: true),
              title: Text(
                name,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                s.title.isEmpty ? '直播中' : s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.visibility,
                      size: 12, color: TrackerTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(_formatCount(s.online),
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              onTap: () => _open(s.roomId.isEmpty
                  ? ''
                  : 'https://live.bilibili.com/${s.roomId}'),
            ),
          );
        },
      );

  Widget _feedCard(FeedItem it) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          dense: true,
          leading: _avatar(it.upFace, live: false),
          title: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: const TextStyle(
                  fontSize: 14, color: TrackerTheme.textPrimary),
              children: <TextSpan>[
                TextSpan(
                  text: '${it.upName.isEmpty ? it.upUid : it.upName} ',
                  style: const TextStyle(
                    color: TrackerTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
                TextSpan(
                  text: it.title.isEmpty ? it.summary : it.title,
                ),
              ],
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: <Widget>[
                _kindChip(it.kind),
                const SizedBox(width: 8),
                Text(
                  _formatTime(it.publishAt),
                  style: const TextStyle(
                      fontSize: 11, color: TrackerTheme.textSecondary),
                ),
              ],
            ),
          ),
          onTap: () => _open(it.url),
        ),
      );

  Widget _avatar(String url, {required bool live}) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: live ? TrackerTheme.live : TrackerTheme.border,
            width: live ? 2 : 1,
          ),
          image: url.isEmpty
              ? null
              : DecorationImage(image: NetworkImage(url), fit: BoxFit.cover),
        ),
        child: url.isEmpty
            ? const Icon(Icons.person,
                size: 18, color: TrackerTheme.textSecondary)
            : null,
      );

  Widget _kindChip(FeedKind kind) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: _kindColor(kind).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          feedKindLabel(kind),
          style: TextStyle(fontSize: 10, color: _kindColor(kind)),
        ),
      );

  static Color _kindColor(FeedKind kind) {
    switch (kind) {
      case FeedKind.video:
        return TrackerTheme.brand;
      case FeedKind.live:
        return TrackerTheme.live;
      case FeedKind.image:
        return Colors.orangeAccent;
      case FeedKind.article:
        return Colors.purpleAccent;
      case FeedKind.repost:
        return Colors.blueGrey;
      default:
        return TrackerTheme.textSecondary;
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

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
