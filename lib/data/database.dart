import 'dart:convert';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 本地库：剧快照、收藏、观看进度。
///
/// 为什么是 sqflite 而不是 drift：见 `docs/adr/0006`——drift 现在要求
/// `sqlite3 ^3.4.0`，而那个包已经迁到 Dart native assets，构建时要从 **github.com**
/// 下载 sqlite3；本机 github 不通，drift 编不出来。sqflite 用平台自带的 SQLite，
/// 不走 native assets，表结构与 SQL 原样保留。
///
/// 三张表的分工：
/// - `drama_snapshots`：剧快照。收藏和历史都要显示标题封面，不该为此重拉详情。
/// - `favorites`：收藏。见 CONTEXT.md 的 Favorite。
/// - `watch_progress`：一集一行。**历史列表是从它派生的**（CONTEXT.md：Watch History
///   derived from Watch Progress），不另设表。
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  /// 打开（首次会建库）。App 启动时调一次。
  ///
  /// 建库版本 **2** 起多了 `library_entries`（剧库快照，见 `docs/adr/0008`）。加表只走
  /// `onUpgrade`，老数据一律不动——收藏 / 历史 / 进度是用户数据，不该为了加一张可重建的
  /// 表而重建库。
  static const int schemaVersion = 2;

  static Future<AppDatabase> open({String name = 'onedrama.db'}) async {
    final directory = await getDatabasesPath();
    final database = await openDatabase(
      p.join(directory, name),
      version: schemaVersion,
      onCreate: (db, version) async {
        await _createCore(db);
        await _createLibrary(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _createLibrary(db);
      },
    );
    return AppDatabase._(database);
  }

  static Future<void> _createCore(Database db) async {
    await db.execute('''
      CREATE TABLE drama_snapshots (
        id             TEXT PRIMARY KEY,
        title          TEXT NOT NULL DEFAULT '',
        cover          TEXT NOT NULL DEFAULT '',
        episode_count  TEXT NOT NULL DEFAULT '',
        category_name  TEXT NOT NULL DEFAULT '',
        remark         TEXT NOT NULL DEFAULT '',
        release_status TEXT NOT NULL DEFAULT '',
        payload        TEXT NOT NULL,
        updated_at     INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE favorites (
        drama_id TEXT PRIMARY KEY,
        added_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE watch_progress (
        drama_id       TEXT NOT NULL,
        video_id       TEXT NOT NULL,
        episode_number INTEGER NOT NULL DEFAULT 0,
        position_ms    INTEGER NOT NULL DEFAULT 0,
        duration_ms    INTEGER NOT NULL DEFAULT 0,
        completed      INTEGER NOT NULL DEFAULT 0,
        updated_at     INTEGER NOT NULL,
        PRIMARY KEY (drama_id, video_id)
      )
    ''');
    // 历史列表要按时间倒序取每部剧最新一条，给它一个索引。
    await db.execute(
      'CREATE INDEX idx_watch_progress_updated '
      'ON watch_progress(updated_at DESC)',
    );
  }

  /// 剧库快照：一部剧一行，按 `(标签, 名次)` 定位。
  ///
  /// `payload` 存整份 Drama JSON——首页要拿它渲染海报卡（标题 / 封面 / 集数 / 角标），
  /// 少一个字段就得多打一次详情，而那正好抵消了「本地优先」的意义。
  static Future<void> _createLibrary(Database db) async {
    await db.execute('''
      CREATE TABLE library_entries (
        tab      INTEGER NOT NULL,
        rank     INTEGER NOT NULL,
        drama_id TEXT NOT NULL,
        payload  TEXT NOT NULL,
        PRIMARY KEY (tab, rank)
      )
    ''');
  }

  Future<void> close() => _db.close();

  /// 记一份剧的快照。收藏或记进度时顺手写。
  Future<void> rememberDrama(Drama drama) async {
    if (drama.id.isEmpty) return;
    await _db.insert('drama_snapshots', <String, Object?>{
      'id': drama.id,
      'title': drama.title,
      'cover': drama.cover,
      'episode_count': drama.episodeCount.isNotEmpty
          ? drama.episodeCount
          : drama.totalEpisode,
      'category_name': drama.categoryName,
      'remark': drama.remark,
      'release_status': drama.releaseStatus,
      'payload': jsonEncode(drama.toJson()),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> isFavorite(String dramaId) async {
    final rows = await _db.query(
      'favorites',
      columns: const ['drama_id'],
      where: 'drama_id = ?',
      whereArgs: [dramaId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 收藏或取消收藏。收藏时顺手写一份剧快照。
  Future<void> setFavorite(Drama drama, bool favorite) async {
    if (favorite) {
      await rememberDrama(drama);
      await _db.insert('favorites', <String, Object?>{
        'drama_id': drama.id,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await _db.delete(
        'favorites',
        where: 'drama_id = ?',
        whereArgs: [drama.id],
      );
    }
  }

  /// 收藏列表，最近收藏在前。
  Future<List<FavoriteEntry>> favoriteList() async {
    final rows = await _db.rawQuery('''
      SELECT f.drama_id, f.added_at, d.payload
      FROM favorites f
      LEFT JOIN drama_snapshots d ON d.id = f.drama_id
      ORDER BY f.added_at DESC
    ''');
    return [
      for (final row in rows)
        FavoriteEntry(
          drama: _dramaOfPayload(
            row['payload'] as String?,
            row['drama_id'] as String,
          ),
          addedAt: _time(row['added_at']),
        ),
    ];
  }

  /// 记进度。进度超过 [completedRatio] 就标成看完。
  Future<void> saveProgress({
    required Drama drama,
    required String videoId,
    required int episodeNumber,
    required int positionMs,
    required int durationMs,
  }) async {
    if (drama.id.isEmpty || videoId.isEmpty) return;
    await rememberDrama(drama);
    final safePosition = positionMs < 0 ? 0 : positionMs;
    final safeDuration = durationMs < 0 ? 0 : durationMs;
    await _db.insert('watch_progress', <String, Object?>{
      'drama_id': drama.id,
      'video_id': videoId,
      'episode_number': episodeNumber,
      'position_ms': safePosition,
      'duration_ms': safeDuration,
      'completed':
          (safeDuration > 0 && safePosition / safeDuration >= completedRatio)
          ? 1
          : 0,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 某部剧的续播点：最后看的那一集。
  Future<ResumePoint?> resumePoint(String dramaId) async {
    final rows = await _db.query(
      'watch_progress',
      where: 'drama_id = ?',
      whereArgs: [dramaId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ResumePoint(
      videoId: row['video_id'] as String,
      episodeNumber: (row['episode_number'] as int?) ?? 0,
      positionMs: (row['position_ms'] as int?) ?? 0,
      durationMs: (row['duration_ms'] as int?) ?? 0,
    );
  }

  /// 历史：一部剧一行，取最后看的那一集，按最后观看时间倒序。
  ///
  /// 「取每部剧最新那一条」用 SQL 的子查询表达最清楚——Dart 侧循环要么全量拉取，
  /// 要么两次往返。
  Future<List<HistoryEntry>> history({int limit = 100}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT p.drama_id, p.video_id, p.episode_number, p.position_ms,
             p.duration_ms, p.updated_at, d.payload
      FROM watch_progress p
      LEFT JOIN drama_snapshots d ON d.id = p.drama_id
      WHERE p.updated_at = (
        SELECT MAX(p2.updated_at)
        FROM watch_progress p2
        WHERE p2.drama_id = p.drama_id
      )
      ORDER BY p.updated_at DESC
      LIMIT ?
      ''',
      [limit],
    );
    return [
      for (final row in rows)
        HistoryEntry(
          drama: _dramaOfPayload(
            row['payload'] as String?,
            row['drama_id'] as String,
          ),
          videoId: row['video_id'] as String,
          episodeNumber: (row['episode_number'] as int?) ?? 0,
          positionMs: (row['position_ms'] as int?) ?? 0,
          durationMs: (row['duration_ms'] as int?) ?? 0,
          updatedAt: _time(row['updated_at']),
        ),
    ];
  }

  /// 清空历史。设置页的「剧库与存储」用它。
  Future<void> clearHistory() => _db.delete('watch_progress');

  /// 清空收藏，并清掉既不收藏也没进度的剧快照。
  Future<void> clearFavorites() async {
    await _db.delete('favorites');
    await _db.delete(
      'drama_snapshots',
      where:
          'id NOT IN (SELECT drama_id FROM favorites) '
          'AND id NOT IN (SELECT drama_id FROM watch_progress)',
    );
  }

  // ---------- 剧库快照 ----------

  /// 整批换掉一个标签的快照。
  ///
  /// **一个事务**：中途失败不留半新半旧——首页拿到半份数据会缺剧，而那看起来像
  /// 「站点没这部剧」，不像一次失败。见 `docs/adr/0008`。
  Future<void> replaceLibraryTab(int tab, List<Drama> dramas) async {
    await _db.transaction((txn) async {
      await txn.delete('library_entries', where: 'tab = ?', whereArgs: [tab]);
      final batch = txn.batch();
      for (var index = 0; index < dramas.length; index++) {
        final drama = dramas[index];
        if (drama.id.isEmpty) continue;
        batch.insert('library_entries', <String, Object?>{
          'tab': tab,
          'rank': index,
          'drama_id': drama.id,
          'payload': jsonEncode(drama.toJson()),
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// 一个标签的快照，按名次。空表示还没导入过（或刚被清掉）。
  Future<List<Drama>> libraryTab(int tab) async {
    final rows = await _db.query(
      'library_entries',
      where: 'tab = ?',
      whereArgs: [tab],
      orderBy: 'rank ASC',
    );
    return [
      for (final row in rows)
        _dramaOfPayload(row['payload'] as String?, row['drama_id'] as String),
    ];
  }

  /// 清掉整份剧库快照，返回删掉的行数。
  ///
  /// 「清除缓存」用它。快照是**可重建的本地副本**，与榜单缓存、封面同一个口径；
  /// 收藏 / 历史 / 进度在别的表里，一个都不受影响。
  Future<int> clearLibrary() => _db.delete('library_entries');

  Drama _dramaOfPayload(String? payload, String fallbackId) {
    if (payload == null || payload.isEmpty) return Drama(id: fallbackId);
    final decoded = decodeJsonObject(payload);
    if (decoded == null) return Drama(id: fallbackId);
    return Drama.fromJson(decoded);
  }
}

/// 收藏列表的一行。
class FavoriteEntry {
  const FavoriteEntry({required this.drama, required this.addedAt});

  final Drama drama;
  final DateTime addedAt;
}

/// 历史列表的一行：剧快照 + 最后看的那一集。
class HistoryEntry {
  const HistoryEntry({
    required this.drama,
    required this.videoId,
    required this.episodeNumber,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final Drama drama;
  final String videoId;
  final int episodeNumber;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  /// 进度百分比，0–1。
  double get ratio =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);
}

/// 续播点：某部剧最后看的那一集与位置。
class ResumePoint {
  const ResumePoint({
    required this.videoId,
    required this.episodeNumber,
    required this.positionMs,
    required this.durationMs,
  });

  final String videoId;
  final int episodeNumber;
  final int positionMs;
  final int durationMs;
}

/// 看完的阈值：进度超过这个比例就算看完。
const double completedRatio = 0.98;

DateTime _time(Object? value) =>
    value is int ? DateTime.fromMillisecondsSinceEpoch(value) : DateTime.now();
