/// 本地 SQLite 数据层。
///
/// 全部数据只落本地：UP 主、动态、直播场次、配置。服务端不存储任何一条。
/// 手写 SQL 而非代码生成，避免额外的 build_runner 步骤。
library db;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../platform/models.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _dbName = 'tracker.db';
  static const int _version = 1;

  Database? _db;

  Future<Database> get database async {
    final Database? existing = _db;
    if (existing != null) return existing;
    final String dir = await getDatabasesPath();
    final String path = p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    final Batch batch = db.batch();

    batch.execute('''
      CREATE TABLE ups (
        platform TEXT NOT NULL,
        uid TEXT NOT NULL,
        name TEXT NOT NULL,
        face TEXT,
        sign TEXT,
        group_name TEXT NOT NULL DEFAULT 'default',
        frequency TEXT NOT NULL DEFAULT 'medium',
        push_dynamic INTEGER NOT NULL DEFAULT 1,
        push_live INTEGER NOT NULL DEFAULT 1,
        show_in_calendar INTEGER NOT NULL DEFAULT 1,
        live_delay_minutes INTEGER NOT NULL DEFAULT 0,
        last_publish_at INTEGER,
        last_sync_at INTEGER,
        followed_at INTEGER,
        PRIMARY KEY (platform, uid)
      )
    ''');

    batch.execute('''
      CREATE TABLE feeds (
        platform TEXT NOT NULL,
        up_uid TEXT NOT NULL,
        item_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        publish_at INTEGER NOT NULL,
        up_name TEXT,
        title TEXT,
        summary TEXT,
        cover TEXT,
        url TEXT,
        notified INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (platform, up_uid, item_id)
      )
    ''');
    batch.execute('CREATE INDEX idx_feeds_publish ON feeds(publish_at DESC)');
    batch.execute('CREATE INDEX idx_feeds_up ON feeds(up_uid)');

    batch.execute('''
      CREATE TABLE live_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        platform TEXT NOT NULL,
        up_uid TEXT NOT NULL,
        room_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        title TEXT,
        peak_online INTEGER NOT NULL DEFAULT 0,
        UNIQUE(platform, up_uid, started_at)
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_live_started ON live_sessions(started_at DESC)');

    // 开播状态快照：靠它识别 0→1 的跳变，避免重复推送
    batch.execute('''
      CREATE TABLE live_state (
        platform TEXT NOT NULL,
        up_uid TEXT NOT NULL,
        room_id TEXT,
        is_live INTEGER NOT NULL DEFAULT 0,
        title TEXT,
        online INTEGER NOT NULL DEFAULT 0,
        started_at INTEGER,
        updated_at INTEGER,
        notified INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (platform, up_uid)
      )
    ''');

    batch.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 首个版本暂无迁移；后续如需加列，在这里按 oldVersion 分段处理
  }

  // ---------------- UP 主 ----------------

  Future<void> upsertUp(UpCreator up) => upsertUps(<UpCreator>[up]);

  /// 批量导入关注列表。
  ///
  /// 刻意不用 replace：每次重新拉关注列表时，若整体覆盖会把用户的分组、
  /// 推送开关、上次同步时间一并冲掉。这里只更新资料字段。
  Future<int> upsertUps(List<UpCreator> ups) async {
    if (ups.isEmpty) return 0;
    final Database db = await database;
    final Batch batch = db.batch();
    for (final UpCreator up in ups) {
      batch.insert(
        'ups',
        <String, Object?>{
          'platform': up.platform,
          'uid': up.uid,
          'name': up.name,
          'face': up.face,
          'sign': up.sign,
          'followed_at':
              (up.followedAt ?? DateTime.now()).millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      batch.update(
        'ups',
        <String, Object?>{
          'name': up.name,
          'face': up.face,
          'sign': up.sign,
        },
        where: 'platform = ? AND uid = ?',
        whereArgs: <Object?>[up.platform, up.uid],
      );
    }
    await batch.commit(noResult: true);
    return ups.length;
  }

  Future<List<UpCreator>> allUps({String? group}) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'ups',
      where: group == null ? null : 'group_name = ?',
      whereArgs: group == null ? null : <Object?>[group],
      orderBy: 'last_publish_at DESC, name ASC',
    );
    return <UpCreator>[
      for (final Map<String, Object?> r in rows) _upFromRow(r)
    ];
  }

  Future<UpCreator?> up(String platform, String uid) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'ups',
      where: 'platform = ? AND uid = ?',
      whereArgs: <Object?>[platform, uid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _upFromRow(rows.first);
  }

  /// 更新抓取/推送配置（保留已抓取数据）。
  Future<void> updateUpConfig(UpCreator up) async {
    final Database db = await database;
    await db.update(
      'ups',
      <String, Object?>{
        'group_name': up.group,
        'frequency': up.frequency.name,
        'push_dynamic': up.pushDynamic ? 1 : 0,
        'push_live': up.pushLive ? 1 : 0,
        'show_in_calendar': up.showInCalendar ? 1 : 0,
        'live_delay_minutes': up.liveDelayMinutes,
      },
      where: 'platform = ? AND uid = ?',
      whereArgs: <Object?>[up.platform, up.uid],
    );
  }

  Future<void> touchUpPublish(String platform, String uid, DateTime at) async {
    final Database db = await database;
    await db.update(
      'ups',
      <String, Object?>{'last_publish_at': at.millisecondsSinceEpoch},
      where: 'platform = ? AND uid = ?',
      whereArgs: <Object?>[platform, uid],
    );
  }

  /// 记录同步完成时间，供频率策略判断是否该抓。
  Future<void> markSynced(String platform, String uid, DateTime at) async {
    final Database db = await database;
    await db.update(
      'ups',
      <String, Object?>{'last_sync_at': at.millisecondsSinceEpoch},
      where: 'platform = ? AND uid = ?',
      whereArgs: <Object?>[platform, uid],
    );
  }

  Future<void> deleteUp(String platform, String uid) async {
    final Database db = await database;
    await db.delete(
      'ups',
      where: 'platform = ? AND uid = ?',
      whereArgs: <Object?>[platform, uid],
    );
    await db.delete(
      'feeds',
      where: 'platform = ? AND up_uid = ?',
      whereArgs: <Object?>[platform, uid],
    );
  }

  // ---------------- 动态 ----------------

  /// 批量写入，已存在则跳过；返回真正新增的条数。
  Future<int> insertFeeds(List<FeedItem> items) async {
    if (items.isEmpty) return 0;
    final Database db = await database;
    final Batch batch = db.batch();
    for (final FeedItem it in items) {
      batch.insert(
        'feeds',
        <String, Object?>{
          'platform': it.platform,
          'up_uid': it.upUid,
          'item_id': it.itemId,
          'kind': it.kind.name,
          'publish_at': it.publishAt.millisecondsSinceEpoch,
          'up_name': it.upName,
          'title': it.title,
          'summary': it.summary,
          'cover': it.cover,
          'url': it.url,
          'notified': 0,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final List<Object?> results = await batch.commit();
    int inserted = 0;
    for (final Object? r in results) {
      if (r is int && r > 0) inserted++;
    }
    return inserted;
  }

  /// 按条件检索，支持考古。
  Future<List<FeedItem>> queryFeeds({
    DateTime? from,
    DateTime? to,
    List<String>? upUids,
    List<FeedKind>? kinds,
    String? keyword,
    String? platform,
    bool onlyNotNotified = false,
    int limit = 200,
    int offset = 0,
  }) async {
    final Database db = await database;
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];

    if (from != null) {
      where.add('publish_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('publish_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (upUids != null && upUids.isNotEmpty) {
      where.add(
          'up_uid IN (${List<String>.filled(upUids.length, '?').join(',')})');
      args.addAll(upUids);
    }
    if (kinds != null && kinds.isNotEmpty) {
      where
          .add('kind IN (${List<String>.filled(kinds.length, '?').join(',')})');
      args.addAll(kinds.map((FeedKind k) => k.name));
    }
    if (platform != null) {
      where.add('platform = ?');
      args.add(platform);
    }
    if (keyword != null && keyword.trim().isNotEmpty) {
      final String like = '%${keyword.trim()}%';
      where.add('(title LIKE ? OR summary LIKE ? OR up_name LIKE ?)');
      args.addAll(<Object?>[like, like, like]);
    }
    if (onlyNotNotified) {
      where.add('notified = 0');
    }

    final List<Map<String, Object?>> rows = await db.query(
      'feeds',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'publish_at DESC',
      limit: limit,
      offset: offset,
    );
    return <FeedItem>[
      for (final Map<String, Object?> r in rows) _feedFromRow(r)
    ];
  }

  Future<void> markNotified(List<FeedItem> items) async {
    if (items.isEmpty) return;
    final Database db = await database;
    final Batch batch = db.batch();
    for (final FeedItem it in items) {
      batch.update(
        'feeds',
        <String, Object?>{'notified': 1},
        where: 'platform = ? AND up_uid = ? AND item_id = ?',
        whereArgs: <Object?>[it.platform, it.upUid, it.itemId],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 日历聚合：返回「日期 → 当天条数」。
  Future<Map<DateTime, int>> dailyCounts({
    DateTime? from,
    DateTime? to,
    bool onlyVisibleUps = true,
  }) async {
    final Database db = await database;
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];

    if (from != null) {
      where.add('publish_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('publish_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (onlyVisibleUps) {
      where.add('''up_uid IN (
        SELECT uid FROM ups WHERE show_in_calendar = 1
      )''');
    }

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''SELECT publish_at FROM feeds
         ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}''',
      args.isEmpty ? null : args,
    );

    final Map<DateTime, int> counts = <DateTime, int>{};
    for (final Map<String, Object?> r in rows) {
      final int? ms = r['publish_at'] as int?;
      if (ms == null) continue;
      final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
      final DateTime day = DateTime(d.year, d.month, d.day);
      counts[day] = (counts[day] ?? 0) + 1;
    }
    return counts;
  }

  // ---------------- 直播 ----------------

  /// 写入状态快照，返回是否为「本次新开播」（0→1 跳变）。
  Future<bool> saveLiveState(LiveStatus status) async {
    final Database db = await database;
    final List<Map<String, Object?>> prev = await db.query(
      'live_state',
      where: 'platform = ? AND up_uid = ?',
      whereArgs: <Object?>[status.platform, status.upUid],
      limit: 1,
    );
    final bool wasLive =
        prev.isNotEmpty && (prev.first['is_live'] as int? ?? 0) == 1;
    final String? prevRoom =
        prev.isEmpty ? null : prev.first['room_id']?.toString();

    await db.insert(
      'live_state',
      <String, Object?>{
        'platform': status.platform,
        'up_uid': status.upUid,
        'room_id': status.roomId,
        'is_live': status.isLive ? 1 : 0,
        'title': status.title,
        'online': status.online,
        'started_at': status.startedAt?.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        // 换房间或重新开播都要重新推送
        'notified':
            (status.isLive && wasLive && prevRoom == status.roomId) ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (status.isLive && !wasLive) {
      await db.insert(
        'live_sessions',
        <String, Object?>{
          'platform': status.platform,
          'up_uid': status.upUid,
          'room_id': status.roomId,
          'started_at':
              (status.startedAt ?? DateTime.now()).millisecondsSinceEpoch,
          'title': status.title,
          'peak_online': status.online,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } else if (!status.isLive && wasLive && prev.isNotEmpty) {
      // 记录下播时间
      await db.update(
        'live_sessions',
        <String, Object?>{'ended_at': DateTime.now().millisecondsSinceEpoch},
        where: 'platform = ? AND up_uid = ? AND ended_at IS NULL',
        whereArgs: <Object?>[status.platform, status.upUid],
      );
    }

    return status.isLive && !wasLive;
  }

  /// 本轮开播是否已推送过（避免重复打扰）。
  Future<bool> isLiveNotified(String platform, String upUid) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'live_state',
      where: 'platform = ? AND up_uid = ?',
      whereArgs: <Object?>[platform, upUid],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['notified'] as int? ?? 0) == 1;
  }

  Future<void> markLiveNotified(String platform, String upUid) async {
    final Database db = await database;
    await db.update(
      'live_state',
      <String, Object?>{'notified': 1},
      where: 'platform = ? AND up_uid = ?',
      whereArgs: <Object?>[platform, upUid],
    );
  }

  Future<List<String>> upsWithLiveEnabled() async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'ups',
      columns: <String>['uid'],
      where: 'push_live = 1',
    );
    return <String>[
      for (final Map<String, Object?> r in rows) r['uid'].toString()
    ];
  }

  /// 当前正在开播的房间。
  Future<List<LiveStatus>> liveNow() async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'live_state',
      where: 'is_live = 1',
      orderBy: 'online DESC',
    );
    return <LiveStatus>[
      for (final Map<String, Object?> r in rows)
        LiveStatus(
          platform: (r['platform'] ?? '').toString(),
          upUid: (r['up_uid'] ?? '').toString(),
          roomId: (r['room_id'] ?? '').toString(),
          isLive: true,
          title: (r['title'] ?? '').toString(),
          online: (r['online'] as int?) ?? 0,
          startedAt: r['started_at'] is int
              ? DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int)
              : null,
        ),
    ];
  }

  Future<List<LiveSession>> liveSessions({DateTime? from, DateTime? to}) async {
    final Database db = await database;
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];
    if (from != null) {
      where.add('started_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('started_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    final List<Map<String, Object?>> rows = await db.query(
      'live_sessions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'started_at DESC',
    );
    return <LiveSession>[
      for (final Map<String, Object?> r in rows)
        LiveSession(
          platform: (r['platform'] ?? '').toString(),
          upUid: (r['up_uid'] ?? '').toString(),
          roomId: (r['room_id'] ?? '').toString(),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            (r['started_at'] as int?) ?? 0,
          ),
          endedAt: r['ended_at'] is int
              ? DateTime.fromMillisecondsSinceEpoch(r['ended_at'] as int)
              : null,
          title: (r['title'] ?? '').toString(),
          peakOnline: (r['peak_online'] as int?) ?? 0,
        ),
    ];
  }

  // ---------------- 配置 KV ----------------

  Future<String?> getSetting(String key) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'kv',
      where: 'k = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['v']?.toString();
  }

  Future<void> setSetting(String key, String value) async {
    final Database db = await database;
    await db.insert(
      'kv',
      <String, Object?>{'k': key, 'v': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------- 清理 ----------------

  /// 清除所有本地数据（设置页一键清理）。
  Future<void> clearAll() async {
    final Database db = await database;
    await db.delete('feeds');
    await db.delete('live_sessions');
    await db.delete('live_state');
    await db.delete('ups');
  }

  Future<int> feedCount() async {
    final Database db = await database;
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT COUNT(*) AS c FROM feeds');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<int> upCount() async {
    final Database db = await database;
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT COUNT(*) AS c FROM ups');
    return (rows.first['c'] as int?) ?? 0;
  }

  // ---------------- 行映射 ----------------

  static UpCreator _upFromRow(Map<String, Object?> r) => UpCreator(
        platform: (r['platform'] ?? '').toString(),
        uid: (r['uid'] ?? '').toString(),
        name: (r['name'] ?? '').toString(),
        face: (r['face'] ?? '').toString(),
        sign: (r['sign'] ?? '').toString(),
        group: (r['group_name'] ?? 'default').toString(),
        frequency: fetchFrequencyFromName(r['frequency']?.toString()),
        pushDynamic: (r['push_dynamic'] as int? ?? 1) == 1,
        pushLive: (r['push_live'] as int? ?? 1) == 1,
        showInCalendar: (r['show_in_calendar'] as int? ?? 1) == 1,
        liveDelayMinutes: (r['live_delay_minutes'] as int?) ?? 0,
        lastPublishAt: r['last_publish_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(r['last_publish_at'] as int)
            : null,
        lastSyncAt: r['last_sync_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(r['last_sync_at'] as int)
            : null,
        followedAt: r['followed_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(r['followed_at'] as int)
            : null,
      );

  static FeedItem _feedFromRow(Map<String, Object?> r) => FeedItem(
        platform: (r['platform'] ?? '').toString(),
        upUid: (r['up_uid'] ?? '').toString(),
        itemId: (r['item_id'] ?? '').toString(),
        kind: feedKindFromName(r['kind']?.toString()),
        publishAt: DateTime.fromMillisecondsSinceEpoch(
          (r['publish_at'] as int?) ?? 0,
        ),
        upName: (r['up_name'] ?? '').toString(),
        title: (r['title'] ?? '').toString(),
        summary: (r['summary'] ?? '').toString(),
        cover: (r['cover'] ?? '').toString(),
        url: (r['url'] ?? '').toString(),
      );
}
