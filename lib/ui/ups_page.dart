import 'package:flutter/material.dart';

import '../main.dart';
import '../platform/models.dart';
import '../service/sync_service.dart';
import 'app.dart';
import 'follow_picker_page.dart';

/// 订阅管理：分组、抓取频率、推送开关。
class UpsPage extends StatefulWidget {
  const UpsPage({super.key});

  @override
  State<UpsPage> createState() => _UpsPageState();
}

class _UpsPageState extends State<UpsPage> {
  static const List<String> kGroups = <String>[
    '核心关注',
    '普通关注',
    '直播优先',
    '静默',
  ];

  List<UpCreator> _ups = <UpCreator>[];
  String _filterGroup = '';
  bool _loading = false;
  final TextEditingController _addCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final List<UpCreator> ups = await appContext.db.allUps(
      group: _filterGroup.isEmpty ? null : _filterGroup,
    );
    if (!mounted) return;
    setState(() => _ups = ups);
  }

  /// 统一的提示入口。
  ///
  /// 为什么单独抽一个方法：`await` 之后再直接用 `context` 会踩
  /// use_build_context_synchronously —— 用户在等待期间切走页面时，
  /// context 已经失效，会抛 "Looking up a deactivated widget's ancestor"。
  /// 把「判断 + 使用」收进这个**没有 await**的方法里，判断与使用之间
  /// 不存在异步间隙，从结构上就不可能出错。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openPicker() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FollowPickerPage(onImported: _load),
      ),
    );
  }

  Future<void> _addUp() async {
    final String input = _addCtrl.text.trim();
    if (input.isEmpty) return;
    setState(() => _loading = true);
    final SyncService sync = SyncService(appContext);
    final UpCreator? up = await sync.addUpByInput(input);
    if (!mounted) return;
    setState(() => _loading = false);

    if (up == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没能识别这个 UID 或链接')),
      );
      return;
    }
    _addCtrl.clear();
    await _load();
    _toast('已添加 ${up.name}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('UP 主 ${_ups.isEmpty ? '' : '· ${_ups.length}'}'),
        actions: <Widget>[
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.playlist_add_check),
            tooltip: '从关注列表里挑选要追更的 UP 主',
            onPressed: _openPicker,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _addBar(),
          _groupChips(),
          const Divider(height: 1),
          Expanded(
            child: _ups.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '还没有追更对象。\n点右上角「选择追更」，从你的 B 站关注列表里勾选；'
                        '也可以在上面输入 UID 手动添加。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: TrackerTheme.textSecondary),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _ups.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _upTile(_ups[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _addBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _addCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '输入 UID 或 space.bilibili.com/123456',
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: TrackerTheme.textSecondary,
                  ),
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
                onSubmitted: (_) => _addUp(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_circle, color: TrackerTheme.brand),
              onPressed: _addUp,
            ),
          ],
        ),
      );

  Widget _groupChips() => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: <Widget>[
            _chip('全部', ''),
            for (final String g in kGroups) _chip(g, g),
          ],
        ),
      );

  Widget _chip(String label, String value) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: _filterGroup == value,
          onSelected: (bool _) {
            setState(() => _filterGroup = value);
            _load();
          },
          backgroundColor: TrackerTheme.surface,
          selectedColor: TrackerTheme.brand.withValues(alpha: 0.2),
          checkmarkColor: TrackerTheme.brand,
          side: const BorderSide(color: TrackerTheme.border),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _upTile(UpCreator up) => ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: TrackerTheme.surfaceAlt,
          backgroundImage: up.face.isEmpty ? null : NetworkImage(up.face),
          child: up.face.isEmpty
              ? const Icon(Icons.person,
                  size: 16, color: TrackerTheme.textSecondary)
              : null,
        ),
        title: Text(
          up.name.isEmpty ? up.uid : up.name,
          style: const TextStyle(fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${up.uid} · ${up.group} · ${_freqLabel(up.frequency)}',
          style:
              const TextStyle(fontSize: 11, color: TrackerTheme.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (up.pushLive)
              const Icon(Icons.live_tv, size: 14, color: TrackerTheme.live),
            if (up.pushDynamic) ...<Widget>[
              const SizedBox(width: 6),
              const Icon(Icons.notifications_active,
                  size: 14, color: TrackerTheme.brand),
            ],
            if (!up.pushDynamic && !up.pushLive)
              const Icon(Icons.notifications_off,
                  size: 14, color: TrackerTheme.textSecondary),
          ],
        ),
        onTap: () => _openConfig(up),
      );

  Future<void> _openConfig(UpCreator up) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TrackerTheme.surface,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _UpConfigSheet(
        up: up,
        onChanged: () => _load(),
      ),
    );
  }

  static String _freqLabel(FetchFrequency f) {
    switch (f) {
      case FetchFrequency.high:
        return '高频';
      case FetchFrequency.medium:
        return '中频';
      case FetchFrequency.low:
        return '低频';
    }
  }
}

class _UpConfigSheet extends StatefulWidget {
  const _UpConfigSheet({required this.up, required this.onChanged});

  final UpCreator up;
  final VoidCallback onChanged;

  @override
  State<_UpConfigSheet> createState() => _UpConfigSheetState();
}

class _UpConfigSheetState extends State<_UpConfigSheet> {
  late UpCreator _up;

  @override
  void initState() {
    super.initState();
    _up = widget.up;
  }

  Future<void> _save() async {
    await appContext.db.updateUpConfig(_up);
    widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 20,
                  backgroundImage:
                      _up.face.isEmpty ? null : NetworkImage(_up.face),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _up.name.isEmpty ? _up.uid : _up.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await appContext.db.deleteUp(_up.platform, _up.uid);
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    widget.onChanged();
                  },
                  child: const Text('删除',
                      style: TextStyle(color: TrackerTheme.live)),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text('分组',
                style:
                    TextStyle(fontSize: 12, color: TrackerTheme.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final String g in _UpsPageState.kGroups)
                  ChoiceChip(
                    label: Text(g, style: const TextStyle(fontSize: 12)),
                    selected: _up.group == g,
                    onSelected: (bool _) => setState(() => _up.group = g),
                    backgroundColor: TrackerTheme.surfaceAlt,
                    selectedColor: TrackerTheme.brand.withValues(alpha: 0.25),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('抓取频率',
                style:
                    TextStyle(fontSize: 12, color: TrackerTheme.textSecondary)),
            const SizedBox(height: 8),
            SegmentedButton<FetchFrequency>(
              segments: const <ButtonSegment<FetchFrequency>>[
                ButtonSegment<FetchFrequency>(
                    value: FetchFrequency.high, label: Text('高')),
                ButtonSegment<FetchFrequency>(
                    value: FetchFrequency.medium, label: Text('中')),
                ButtonSegment<FetchFrequency>(
                    value: FetchFrequency.low, label: Text('低')),
              ],
              selected: <FetchFrequency>{_up.frequency},
              onSelectionChanged: (Set<FetchFrequency> s) =>
                  setState(() => _up.frequency = s.first),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('推送新动态', style: TextStyle(fontSize: 13)),
              value: _up.pushDynamic,
              onChanged: (bool v) => setState(() => _up.pushDynamic = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('推送开播', style: TextStyle(fontSize: 13)),
              value: _up.pushLive,
              onChanged: (bool v) => setState(() => _up.pushLive = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('在日历中显示', style: TextStyle(fontSize: 13)),
              value: _up.showInCalendar,
              onChanged: (bool v) => setState(() => _up.showInCalendar = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const Text('开播延迟推送', style: TextStyle(fontSize: 13)),
                const Spacer(),
                Text('${_up.liveDelayMinutes} 分钟',
                    style: const TextStyle(
                        fontSize: 12, color: TrackerTheme.textSecondary)),
              ],
            ),
            Slider(
              value: _up.liveDelayMinutes.toDouble(),
              min: 0,
              max: 30,
              divisions: 6,
              activeColor: TrackerTheme.brand,
              onChanged: (double v) =>
                  setState(() => _up.liveDelayMinutes = v.round()),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TrackerTheme.brand,
                  foregroundColor: Colors.white,
                ),
                onPressed: _save,
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
