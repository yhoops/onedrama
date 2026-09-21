import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_pager.dart';
import 'database.dart';
import 'library_tabs.dart';

/// 导入的两个阶段。设置页那行按它给文案。
enum LibraryImportStage { catalog, covers }

/// 一次导入的进度。
class LibraryImportProgress {
  const LibraryImportProgress({
    required this.stage,
    required this.done,
    required this.total,
  });

  final LibraryImportStage stage;
  final int done;
  final int total;

  String get label => switch (stage) {
    LibraryImportStage.catalog => '导入剧库 $done/$total',
    LibraryImportStage.covers => '缓存封面 $done/$total',
  };
}

/// 一次导入的结果。
class LibraryImportReport {
  const LibraryImportReport({
    required this.counts,
    required this.coversWarmed,
  });

  /// 标签下标 → 落盘的部数。**-1 表示这个标签失败了，保留了旧数据**。
  final Map<int, int> counts;

  final int coversWarmed;

  int get dramas => counts.values.where((count) => count > 0).fold(0, (a, b) => a + b);
  int get failedTabs => counts.values.where((count) => count < 0).length;
  bool get ok => failedTabs == 0;
}

/// 剧库导入。见 `docs/adr/0008`。
///
/// 每次启动自动跑一遍（`main.dart` 里第一帧之后），设置「剧库与存储 → 更新剧库」手动
/// 再跑一次。范围很小：只负责「把四个标签的头部若干页换进本地快照」，不碰 UI。
class LibraryImporter {
  LibraryImporter({
    required this.client,
    required this.database,
    required this.prefs,
    this.pagesPerTab = defaultPagesPerTab,
  });

  /// 每个标签拉几页。分类接口 `limit=18`，所以 5 页 = 90 部、每个标签 5 次签名请求。
  static const int defaultPagesPerTab = 5;

  /// 封面预取的并发。360 张、每张约 24 KB，串行会慢到让人以为卡住。
  static const int _coverConcurrency = 4;

  static const String _keyImportedAt = 'library_imported_at';

  final HongguoClient client;
  final AppDatabase database;
  final SharedPreferences prefs;
  final int pagesPerTab;

  /// 正在跑的那一轮的进度；没在跑时为 null。
  ///
  /// 用 `ValueNotifier` 而不是回调：自动那一轮与用户按下的那一轮可能撞上，而设置页需要
  /// 在任何时候都能看到「现在在干什么」。
  final ValueNotifier<LibraryImportProgress?> progress = ValueNotifier(null);

  Future<LibraryImportReport>? _inFlight;

  bool get isRunning => _inFlight != null;

  /// 上次导入成功的时间。没导入过是 null。
  DateTime? lastImportedAt() {
    final at = prefs.getInt(_keyImportedAt);
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// 忘掉「上次导入」的时间戳。清缓存时一起调——快照都没了，再说「3 分钟前更新」是骗人。
  Future<void> forgetImportedAt() => prefs.remove(_keyImportedAt);

  /// 跑一遍。
  ///
  /// **已经有在飞的那一轮就搭车**，不再起一轮：启动时那一轮和用户按下的那一轮会撞上，
  /// 两轮同时替换同一个标签的表会互相覆盖。
  Future<LibraryImportReport> run() {
    final existing = _inFlight;
    if (existing != null) return existing;
    late final Future<LibraryImportReport> task;
    task = _run().whenComplete(() {
      if (identical(_inFlight, task)) {
        _inFlight = null;
        progress.value = null;
      }
    });
    _inFlight = task;
    return task;
  }

  /// **一个标签失败只丢这个标签**：保留它上次的快照，其余标签照常替换。整批回滚会让一次
  /// 抖动把四个标签全变成旧的，而按标签隔离之后最坏也只是四个里旧一个。
  Future<LibraryImportReport> _run() async {
    final startedAt = DateTime.now();
    final pages = libraryTabs.length * pagesPerTab;
    final counts = <int, int>{};
    final covers = <String>[];

    for (var tab = 0; tab < libraryTabs.length; tab++) {
      progress.value = LibraryImportProgress(
        stage: LibraryImportStage.catalog,
        done: tab * pagesPerTab,
        total: pages,
      );
      try {
        final dramas = await _fetchTab(tab, (fetched) {
          progress.value = LibraryImportProgress(
            stage: LibraryImportStage.catalog,
            done: tab * pagesPerTab + fetched,
            total: pages,
          );
        });
        await database.replaceLibraryTab(tab, dramas);
        counts[tab] = dramas.length;
        for (final drama in dramas) {
          if (drama.cover.isNotEmpty) covers.add(drama.cover);
        }
      } catch (_) {
        counts[tab] = -1;
      }
    }

    // 四个标签全挂，多半是一次性断网或撞上拦截页——那就当这一轮没发生，别把时间戳推新，
    // 否则设置页会显示「刚刚更新」而本地还是旧的。
    if (counts.values.any((count) => count >= 0)) {
      await prefs.setInt(_keyImportedAt, DateTime.now().millisecondsSinceEpoch);
    }

    final warmed = await _warmCovers(covers);
    final report = LibraryImportReport(counts: counts, coversWarmed: warmed);
    // 刻意留的取证痕迹（同 `[prefetch]` 那套）：`adb logcat -s flutter` 能看到每次启动
    // 这一轮到底导进去了多少、哪个标签失败了。
    debugPrint(
      '[library] 导入完成 · ${report.dramas} 部'
      ' · 逐标签 ${counts.entries.map((e) => '${e.key}:${e.value}').join(' ')}'
      ' · 封面 $warmed 张'
      ' · ${DateTime.now().difference(startedAt).inSeconds}s',
    );
    return report;
  }

  Future<List<Drama>> _fetchTab(int tab, void Function(int) onPage) async {
    final pager = CatalogPager(client: client, tab: libraryTabs[tab]);
    final out = <Drama>[];
    for (var page = 0; page < pagesPerTab; page++) {
      final fresh = await pager.next();
      onPage(page + 1);
      // 上游说没有更多了：这个标签到此为止，剩下的页数不拉（进度由下一个标签接上）。
      if (fresh.isEmpty) break;
      out.addAll(fresh);
    }
    return out;
  }

  /// 顺手把封面写进磁盘缓存。
  ///
  /// 不做这一步，「本地优先」就只兑现了一半：断网时首页是一排灰块，只有剧名。360 张、
  /// 每张约 24 KB，合计约 8.6 MB（见 ADR-0008）。
  Future<int> _warmCovers(List<String> urls) async {
    if (urls.isEmpty) return 0;
    final manager = DefaultCacheManager();
    final queue = <String>[...urls];
    var done = 0;
    var warmed = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final url = queue.removeLast();
        try {
          if (await manager.getFileFromCache(url) == null) {
            await manager.downloadFile(url);
            warmed++;
          }
        } catch (_) {
          // 单张封面失败不该中断整轮；断网时它会一路失败，那也是正常结果。
        }
        done++;
        progress.value = LibraryImportProgress(
          stage: LibraryImportStage.covers,
          done: done,
          total: urls.length,
        );
      }
    }

    await Future.wait([for (var i = 0; i < _coverConcurrency; i++) worker()]);
    return warmed;
  }
}
