import 'package:flutter/material.dart';

import '../main.dart';
import '../platform/models.dart';
import '../service/sync_service.dart';
import 'app.dart';
import 'login_page.dart';

/// 从 B 站关注列表里挑选要追更的 UP 主。
///
/// 策略调整（2026-10-02）：
/// 旧做法是「点一下就自动把全部关注导入」，但关注列表动辄几百位，
/// 导入后每一轮抓取都要对几百个 UP 串行请求（几十分钟，且极易触发风控），
/// 实际跑不通。现改为：**一次性拉全量列表 → 用户自己勾选 → 只导入选中的几位**。
///
/// 输入：登录态（Cookie，用于读关注列表）+ 用户的勾选。
/// 输出：被勾选的 UP 主写入本地库（成为追更对象），其余只是展示，不落库。
class FollowPickerPage extends StatefulWidget {
  const FollowPickerPage({super.key, this.onImported});

  /// 导入成功后回调（由「UP 主」页传入，用于刷新已追更列表）。
  final VoidCallback? onImported;

  @override
  State<FollowPickerPage> createState() => _FollowPickerPageState();
}

class _FollowPickerPageState extends State<FollowPickerPage> {
  final TextEditingController _searchCtrl = TextEditingController();

  /// 全量关注列表（本地过滤的源数据）。
  List<UpCreator> _all = <UpCreator>[];

  /// 本次勾选、待导入的 UID。
  final Set<String> _selected = <String>{};

  /// 已追更 UP 的 key（`platform:uid`）。
  Set<String> _tracked = <String>{};

  bool _loading = false;
  int _got = 0;
  int _total = -1;
  DateTime? _cachedAt;
  String _keyword = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final SyncService sync = SyncService(appContext);
    _tracked = await sync.trackedKeys();
    final FollowListResult? cached = await sync.loadCachedFollowings();
    if (!mounted) return;

    if (cached != null) {
      // 有缓存就先秒开，是否重新拉取交给用户决定（避免每次打开都等）
      setState(() {
        _all = cached.ups;
        _total = cached.total;
        _cachedAt = cached.cachedAt;
      });
      return;
    }
    await _fetch();
  }

  /// 实时拉取完整关注列表（分页，带进度）。
  Future<void> _fetch() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _got = 0;
      _total = -1;
    });

    final SyncService sync = SyncService(appContext);
    final FollowListResult result = await sync.fetchFollowings(
      onProgress: (int got, int total) {
        if (!mounted) return;
        setState(() {
          _got = got;
          _total = total;
        });
      },
    );
    if (!mounted) return;

    if (result.cookieInvalid) {
      setState(() => _loading = false);
      _promptLogin();
      return;
    }

    await sync.cacheFollowings(result);
    if (!mounted) return;

    setState(() {
      _loading = false;
      _all = result.ups;
      _total = result.total;
      _cachedAt = DateTime.now();
      _error = result.hasError ? result.messages.first : null;
      // 已不在关注列表里的勾选要剔除，避免导入了取不到资料的项
      _selected.removeWhere(
        (String uid) => !result.ups.any((UpCreator up) => up.uid == uid),
      );
    });
  }

  void _promptLogin() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('登录已失效，请重新登录后再拉取关注列表'),
        action: SnackBarAction(
          label: '去登录',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LoginPage()),
          ),
        ),
      ),
    );
  }

  /// 按关键词过滤（名字 / UID，纯本地，不再请求接口）。
  List<UpCreator> get _visible {
    final String kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return _all;
    return <UpCreator>[
      for (final UpCreator up in _all)
        if (up.name.toLowerCase().contains(kw) || up.uid.contains(kw)) up,
    ];
  }

  bool _isTracked(UpCreator up) => _tracked.contains(up.key);

  int get _visibleSelectable =>
      _visible.where((UpCreator up) => !_isTracked(up)).length;

  void _selectAllVisible() {
    setState(() {
      for (final UpCreator up in _visible) {
        if (!_isTracked(up)) _selected.add(up.uid);
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _confirm() async {
    if (_selected.isEmpty) return;
    final List<UpCreator> picked = <UpCreator>[
      for (final UpCreator up in _all)
        if (_selected.contains(up.uid)) up,
    ];
    final int n = await SyncService(appContext).importSelected(picked);
    if (!mounted) return;

    setState(() {
      _tracked = <String>{..._tracked, for (final UpCreator up in picked) up.key};
      _selected.clear();
    });
    widget.onImported?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已加入追更 $n 位 UP 主')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('选择追更 · ${_all.length} 位关注'),
        actions: <Widget>[
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: '重新拉取关注列表',
            onPressed: _loading ? null : _fetch,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _searchBar(),
          _statusBar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: TextField(
          controller: _searchCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search,
                size: 18, color: TrackerTheme.textSecondary),
            hintText: '在关注列表里搜索（名字 / UID）',
            hintStyle:
                const TextStyle(fontSize: 12, color: TrackerTheme.textSecondary),
            isDense: true,
            filled: true,
            fillColor: TrackerTheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: TrackerTheme.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: TrackerTheme.border),
            ),
          ),
          onChanged: (String v) => setState(() => _keyword = v),
        ),
      );

  Widget _statusBar() {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(
              // clamp 返回 num，显式转 double 以匹配参数类型
              value: _total > 0 ? (_got / _total).clamp(0.0, 1.0).toDouble() : null,
              backgroundColor: TrackerTheme.surfaceAlt,
              color: TrackerTheme.brand,
              minHeight: 4,
            ),
            const SizedBox(height: 6),
            Text(
              _total > 0
                  ? '正在读取关注列表… 已获取 $_got / $_total'
                  : '正在读取关注列表… 已获取 $_got',
              style: const TextStyle(
                  fontSize: 11, color: TrackerTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    final String cacheHint = _cachedAt == null
        ? ''
        : ' · 列表更新于 ${_timeAgo(_cachedAt!)}';
    final String hint = _all.isEmpty
        ? '（列表为空，点右上角 ↻ 重试）'
        : '共 ${_all.length} 位关注 · 已追更 ${_tracked.length} 位$cacheHint';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            hint,
            style:
                const TextStyle(fontSize: 11, color: TrackerTheme.textSecondary),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              _error!,
              style: const TextStyle(fontSize: 11, color: TrackerTheme.live),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    if (_visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _all.isEmpty
                ? '还没有拉到关注列表。\n请确认已登录 B 站账号，然后点右上角 ↻ 重试。'
                : '没有匹配「$_keyword」的 UP 主',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, color: TrackerTheme.textSecondary),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _visible.length,
      itemBuilder: (BuildContext context, int i) => _tile(_visible[i]),
    );
  }

  Widget _tile(UpCreator up) {
    final bool tracked = _isTracked(up);
    final bool checked = tracked || _selected.contains(up.uid);
    return CheckboxListTile(
      dense: true,
      value: checked,
      // 已追更的不可在此取消（取消追更要到「UP 主」页里删），避免误操作
      onChanged: tracked
          ? null
          : (bool? v) => setState(() {
                if (v == true) {
                  _selected.add(up.uid);
                } else {
                  _selected.remove(up.uid);
                }
              }),
      controlAffinity: ListTileControlAffinity.leading,
      secondary: CircleAvatar(
        radius: 18,
        backgroundColor: TrackerTheme.surfaceAlt,
        backgroundImage:
            up.face.isEmpty ? null : NetworkImage(up.face),
        child: up.face.isEmpty
            ? const Icon(Icons.person,
                size: 16, color: TrackerTheme.textSecondary)
            : null,
      ),
      title: Text(
        up.name.isEmpty ? up.uid : up.name,
        style: TextStyle(
          fontSize: 14,
          color: tracked ? TrackerTheme.textSecondary : TrackerTheme.textPrimary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        tracked ? '已追更 · ${up.uid}' : up.uid,
        style: const TextStyle(fontSize: 11, color: TrackerTheme.textSecondary),
      ),
    );
  }

  Widget _bottomBar() {
    final int n = _selected.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: <Widget>[
            OutlinedButton(
              onPressed: n > 0 ? _clearSelection : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: TrackerTheme.textSecondary,
                side: const BorderSide(color: TrackerTheme.border),
              ),
              child: const Text('清空'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _visibleSelectable > 0 ? _selectAllVisible : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: TrackerTheme.accent,
                side: const BorderSide(color: TrackerTheme.border),
              ),
              child: const Text('全选当前'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TrackerTheme.brand,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: TrackerTheme.surfaceAlt,
                  disabledForegroundColor: TrackerTheme.textSecondary,
                ),
                onPressed: n > 0 ? _confirm : null,
                child: Text(n > 0 ? '加入追更（$n）' : '请勾选要追更的 UP 主'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _timeAgo(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}
