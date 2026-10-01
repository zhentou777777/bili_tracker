import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../platform/models.dart';
import 'app.dart';

/// 考古检索：按关键词、UP 主、内容类型、时间范围回溯本地已抓取内容。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _ctrl = TextEditingController();

  List<FeedItem> _results = <FeedItem>[];
  final Set<FeedKind> _kinds = <FeedKind>{};
  String _upUid = '';
  int _rangeDays = 30;
  bool _searched = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final DateTime? from = _rangeDays > 0
        ? DateTime.now().subtract(Duration(days: _rangeDays))
        : null;

    final List<FeedItem> items = await appContext.db.queryFeeds(
      from: from,
      upUids: _upUid.isEmpty ? null : <String>[_upUid],
      kinds: _kinds.isEmpty ? null : _kinds.toList(),
      keyword: _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim(),
      limit: 300,
    );
    if (!mounted) return;
    setState(() {
      _results = items;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('考古检索')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(fontSize: 13),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜索标题、正文或 UP 主名',
                hintStyle: const TextStyle(
                  fontSize: 12,
                  color: TrackerTheme.textSecondary,
                ),
                prefixIcon: const Icon(Icons.search, size: 18),
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
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: <Widget>[
                for (final FeedKind k in FeedKind.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(feedKindLabel(k),
                          style: const TextStyle(fontSize: 11)),
                      selected: _kinds.contains(k),
                      onSelected: (bool v) {
                        setState(() {
                          if (v) {
                            _kinds.add(k);
                          } else {
                            _kinds.remove(k);
                          }
                        });
                        _search();
                      },
                      backgroundColor: TrackerTheme.surface,
                      selectedColor: TrackerTheme.brand.withValues(alpha: 0.2),
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(color: TrackerTheme.border),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                for (final MapEntry<String, int> r in <MapEntry<String, int>>[
                  const MapEntry<String, int>('7 天', 7),
                  const MapEntry<String, int>('30 天', 30),
                  const MapEntry<String, int>('90 天', 90),
                  const MapEntry<String, int>('全部', 0),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(r.key, style: const TextStyle(fontSize: 11)),
                      selected: _rangeDays == r.value,
                      onSelected: (bool _) {
                        setState(() => _rangeDays = r.value);
                        _search();
                      },
                      backgroundColor: TrackerTheme.surface,
                      selectedColor: TrackerTheme.brand.withValues(alpha: 0.2),
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(color: TrackerTheme.border),
                    ),
                  ),
                const Spacer(),
                FutureBuilder<List<UpCreator>>(
                  future: appContext.db.allUps(),
                  builder: (BuildContext context,
                      AsyncSnapshot<List<UpCreator>> snap) {
                    final List<UpCreator> ups = snap.data ?? <UpCreator>[];
                    return DropdownButton<String>(
                      value: _upUid,
                      hint:
                          const Text('全部 UP 主', style: TextStyle(fontSize: 11)),
                      style: const TextStyle(
                          fontSize: 11, color: TrackerTheme.textPrimary),
                      dropdownColor: TrackerTheme.surfaceAlt,
                      underline: const SizedBox(),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('全部 UP 主'),
                        ),
                        for (final UpCreator u in ups)
                          DropdownMenuItem<String>(
                            value: u.uid,
                            child: Text(
                              u.name.isEmpty ? u.uid : u.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (String? v) {
                        setState(() => _upUid = v ?? '');
                        _search();
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: !_searched
                ? const Center(
                    child: Text(
                      '输入关键词开始检索本地已抓取内容',
                      style: TextStyle(
                          color: TrackerTheme.textSecondary, fontSize: 13),
                    ),
                  )
                : _results.isEmpty
                    ? const Center(
                        child: Text(
                          '没有匹配结果',
                          style: TextStyle(
                              color: TrackerTheme.textSecondary, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (BuildContext context, int i) {
                          final FeedItem it = _results[i];
                          return ListTile(
                            dense: true,
                            title: Text(
                              it.title.isEmpty ? it.summary : it.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '${it.upName} · ${feedKindLabel(it.kind)} · ${_ymd(it.publishAt)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: TrackerTheme.textSecondary,
                              ),
                            ),
                            onTap: () async {
                              if (it.url.isEmpty) return;
                              final Uri uri = Uri.parse(it.url);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  static String _ymd(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
