import 'package:flutter/material.dart';

import '../main.dart';
import '../platform/models.dart';
import 'app.dart';

/// 动态日历：按日聚合，可切月历 / 周历。
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _focus;
  late DateTime _selected;
  Map<DateTime, int> _counts = <DateTime, int>{};
  Map<DateTime, int> _liveCounts = <DateTime, int>{};
  List<FeedItem> _dayItems = <FeedItem>[];
  bool _weekMode = false;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _focus = DateTime(now.year, now.month, 1);
    _selected = DateTime(now.year, now.month, now.day);
    _load();
  }

  DateTime get _rangeStart {
    final DateTime first = _weekMode
        ? _selected.subtract(Duration(days: _selected.weekday - 1))
        : _focus;
    final DateTime d = DateTime(first.year, first.month, first.day);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  DateTime get _rangeEnd {
    if (_weekMode) return _rangeStart.add(const Duration(days: 6));
    final DateTime lastMonthDay = DateTime(_focus.year, _focus.month + 1, 0);
    final DateTime d =
        DateTime(lastMonthDay.year, lastMonthDay.month, lastMonthDay.day);
    return d.add(Duration(days: 7 - d.weekday));
  }

  Future<void> _load() async {
    final DateTime from = _rangeStart;
    final DateTime to = _rangeEnd
        .add(const Duration(days: 1))
        .subtract(const Duration(seconds: 1));

    final Map<DateTime, int> counts = await appContext.db.dailyCounts(
      from: from,
      to: to,
    );
    final List<LiveSession> sessions = await appContext.db.liveSessions(
      from: from,
      to: to,
    );

    final Map<DateTime, int> lives = <DateTime, int>{};
    for (final LiveSession s in sessions) {
      final DateTime day =
          DateTime(s.startedAt.year, s.startedAt.month, s.startedAt.day);
      lives[day] = (lives[day] ?? 0) + 1;
    }

    final List<FeedItem> dayItems = await appContext.db.queryFeeds(
      from: _selected,
      to: _selected
          .add(const Duration(days: 1))
          .subtract(const Duration(seconds: 1)),
      limit: 100,
    );

    if (!mounted) return;
    setState(() {
      _counts = counts;
      _liveCounts = lives;
      _dayItems = dayItems;
    });
  }

  void _pick(DateTime day) {
    setState(() => _selected = day);
    _load();
  }

  void _shiftMonth(int delta) {
    setState(() => _focus = DateTime(_focus.year, _focus.month + delta, 1));
    _load();
  }

  void _shiftWeek(int delta) {
    setState(() {
      _selected = _selected.add(Duration(days: 7 * delta));
      _focus = DateTime(_selected.year, _selected.month, 1);
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('更新日历'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: false, label: Text('月')),
                ButtonSegment<bool>(value: true, label: Text('周')),
              ],
              selected: <bool>{_weekMode},
              onSelectionChanged: (Set<bool> s) {
                setState(() => _weekMode = s.first);
                _load();
              },
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _header(),
          _weekdayRow(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  _grid(),
                  const Divider(height: 24),
                  _dayList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _weekMode ? _shiftWeek(-1) : _shiftMonth(-1),
            ),
            Expanded(
              child: Text(
                _weekMode
                    ? '${_fmt(_rangeStart)} – ${_fmt(_rangeEnd)}'
                    : '${_focus.year} 年 ${_focus.month} 月',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _weekMode ? _shiftWeek(1) : _shiftMonth(1),
            ),
          ],
        ),
      );

  Widget _weekdayRow() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            for (final String w in <String>['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                        fontSize: 12, color: TrackerTheme.textSecondary),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _grid() {
    final DateTime start = _rangeStart;
    final int days = _weekMode ? 7 : 42;
    final List<Widget> cells = <Widget>[];

    for (int i = 0; i < days; i++) {
      final DateTime d = start.add(Duration(days: i));
      final bool inMonth = d.month == _focus.month || _weekMode;
      final bool isToday = _sameDay(d, DateTime.now());
      final bool isSel = _sameDay(d, _selected);
      final int count = _counts[DateTime(d.year, d.month, d.day)] ?? 0;
      final int live = _liveCounts[DateTime(d.year, d.month, d.day)] ?? 0;

      cells.add(
        GestureDetector(
          onTap: () => _pick(d),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isSel
                  ? TrackerTheme.brand.withOpacity(0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isToday ? TrackerTheme.brand : Colors.transparent,
                width: 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '${d.day}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                    color: inMonth
                        ? (isSel
                            ? TrackerTheme.brand
                            : TrackerTheme.textPrimary)
                        : TrackerTheme.textSecondary.withOpacity(0.4),
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 14,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (count > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: _heatColor(count),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                                fontSize: 9, color: Colors.white),
                          ),
                        ),
                      if (live > 0) ...<Widget>[
                        const SizedBox(width: 2),
                        const Icon(Icons.circle,
                            size: 5, color: TrackerTheme.live),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 7,
        childAspectRatio: 1,
        children: cells,
      ),
    );
  }

  Widget _dayList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Text(
            '${_fmt(_selected)} · ${_dayItems.length} 条',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        if (_dayItems.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                '这一天没有记录',
                style:
                    TextStyle(color: TrackerTheme.textSecondary, fontSize: 13),
              ),
            ),
          )
        else
          for (final FeedItem it in _dayItems) _CalendarFeedRow(item: it),
      ],
    );
  }

  /// 条数越多颜色越亮，一眼看出哪天更新密集。
  static Color _heatColor(int count) {
    if (count >= 10) return const Color(0xFFFF4D6D);
    if (count >= 5) return const Color(0xFFFB7299);
    if (count >= 3) return const Color(0xFFC4566F);
    return const Color(0xFF6B7A90);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _fmt(DateTime d) => '${d.month}/${d.day}';
}

class _CalendarFeedRow extends StatelessWidget {
  const _CalendarFeedRow({required this.item});

  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: TrackerTheme.surfaceAlt,
        backgroundImage: item.upFace.isEmpty ? null : NetworkImage(item.upFace),
        child: item.upFace.isEmpty
            ? const Icon(Icons.person,
                size: 14, color: TrackerTheme.textSecondary)
            : null,
      ),
      title: Text(
        item.title.isEmpty ? item.summary : item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        '${item.upName} · ${feedKindLabel(item.kind)} · ${_hhmm(item.publishAt)}',
        style: const TextStyle(fontSize: 11, color: TrackerTheme.textSecondary),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
