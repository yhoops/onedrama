import 'package:flutter/foundation.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_pager.dart';
import 'cover_cache.dart';
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
    required this.added,
    required this.coversWarmed,
    required this.firstImport,
  });

  /// 标签下标 → 落盘的部数。**-1 表示这个标签失败了，保留了旧数据**。
  final Map<int, int> counts;

  /// 分类标签里**这次新出现**的剧 ID 数（相对上一份快照）。见 `CONTEXT.md` 的
  /// Newly Added。综合不计——它是推荐流，每次拉到的几乎全是另一批。
  final int added;

  final int coversWarmed;

  /// 这一轮之前本地没有任何分类标签的快照（全新安装，或刚按过「清除缓存」）。
  ///
  /// 这时 [added] 就是全部部数，报「新增 270 部」会像是上游一次上了 270 部，所以
  /// 设置页在这时不弹窗——见 [importToast]。
  final bool firstImport;

  /// 这一轮**落盘**的部数之和（含综合）。
  ///
  /// 不是剧库部数：那个要去重，由 `AppDatabase.libraryCount()` 说了算。这个数只用于
  /// 日志——它回答的是「这一轮写进去多少条」。
  int get dramas =>
      counts.values.where((count) => count > 0).fold(0, (a, b) => a + b);
  int get failedTabs => counts.values.where((count) => count < 0).length;
  bool get ok => failedTabs == 0;
}

/// 点「更新剧库」跑完之后那条 SnackBar 的文案。返回 null 表示**不弹**。
///
/// 抽成顶层函数是为了能单测：三条分支（首次不弹、正常、部分失败）写错了都不会报错，
/// 只会表现成「弹窗说的数不对」——而那要到用户抱怨时才发现。
///
/// [libraryCount] 是跑完之后从库里读出来的剧库部数（`AppDatabase.libraryCount()`），
/// 不是这一轮落盘的行数：两者含不含综合、去不去重都不一样。
String? importToast(LibraryImportReport report, {required int libraryCount}) {
  if (report.firstImport) {
    // 首次导入没有「新增」可言——那时新增就是全部。但失败得说，否则全新安装下点一次
    // 「更新剧库」会一点反馈都没有（那一行还是「尚未更新」）。
    if (report.ok) return null;
    return libraryCount > 0
        ? '首次导入 $libraryCount 部 · ${report.failedTabs} 个标签没拉成'
        : '${report.failedTabs} 个标签都没拉成，本地还没有剧库数据';
  }
  final parts = <String>['本次新增 ${report.added} 部，剧库共 $libraryCount 部'];
  if (report.failedTabs > 0) {
    parts.add('${report.failedTabs} 个标签没更新上，保留了旧数据');
  }
  return parts.join(' · ');
}

/// 剧库导入。见 `docs/adr/0008` 与 `docs/adr/0012`。
///
/// **只在首次进入 App 时自动跑一遍**（`main.dart` 里第一帧之后，判据见
/// [startupImportDone]），之后都由设置「剧库与存储 → 更新剧库」手动触发。范围很小：
/// 只负责「把四个标签的头部若干页换进本地快照」，不碰 UI。
///
/// 它同时是**剧库部数与「本次新增」**的来源——那两个数只算分类标签，口径见
/// `docs/adr/0010`。
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
  static const String _keyStartupImportDone = 'library_startup_import_done';

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

  /// 「首次进入 App 时那一轮自动导入」是否已经跑过。
  ///
  /// **与 [lastImportedAt] 是两件事，刻意分开记**：
  /// - [lastImportedAt] 只在分类标签成功时才推进，它是给用户看「这份数据多旧」的；
  /// - 这个只要跑过就置位，**失败也算跑过**——否则每次启动都会再试一轮，而「按过清除缓存
  ///   之后又被自动拉一份」正是这条口径要避免的（用户清缓存就是为了腾空间）。
  ///
  /// 所以 [forgetImportedAt] **不碰它**，清缓存只清快照与时间戳。
  bool startupImportDone() => prefs.getBool(_keyStartupImportDone) ?? false;

  Future<void> markStartupImportDone() =>
      prefs.setBool(_keyStartupImportDone, true);

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

    // 「本次新增」必须在替换前把上一份快照的 ID 读出来：replaceLibraryTab 是先 delete
    // 再 insert，替换之后就问不出「上次有哪些」了。
    //
    // **只读分类标签**：综合是推荐流，它那 90 部每次几乎全是新面孔（实测连拉两次第 1
    // 页只有约六成重叠），算进去「新增」会常年顶在几十部。见 `CONTEXT.md` 的
    // Newly Added。
    final before = <int, Set<String>>{};
    var hadSnapshot = false;
    for (final tab in categoryTabIndexes) {
      final ids = await database.libraryTabIds(tab);
      before[tab] = ids;
      if (ids.isNotEmpty) hadSnapshot = true;
    }

    var added = 0;

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
        // 新增只数分类标签里没见过的。失败的标签在 `before` 里有值但走不到这里——
        // 它的旧快照原封不动，本来也就没有「新增」。
        final previous = before[tab];
        if (previous != null) {
          for (final drama in dramas) {
            if (drama.id.isNotEmpty && !previous.contains(drama.id)) added++;
          }
        }
        for (final drama in dramas) {
          if (drama.cover.isNotEmpty) covers.add(drama.cover);
        }
      } catch (_) {
        counts[tab] = -1;
      }
    }

    // 分类标签全挂，多半是一次性断网或撞上拦截页——那就当这一轮没发生，别把时间戳推新，
    // 否则设置页会显示「刚刚」而本地还是旧的。
    //
    // 判据是**分类标签**而不是四个标签（[ADR-0010]）：设置页那一行是「267 部 · 3 分钟前」，
    // 而 267 是分类标签的部数。要是综合成功、三个分类标签全挂也把时间推新，那一行就会说
    // 「267 部 · 刚刚」——可那个 267 是两天前的。宁可让它显示「2天前」：那正是最需要
    // 知道的时候。
    //
    // [ADR-0010]: docs/adr/0010-library-count-excludes-the-recommendation-tab.md
    if (categoryTabIndexes.any((tab) => (counts[tab] ?? -1) >= 0)) {
      await prefs.setInt(_keyImportedAt, DateTime.now().millisecondsSinceEpoch);
    }

    final warmed = await _warmCovers(covers);
    final report = LibraryImportReport(
      counts: counts,
      added: added,
      coversWarmed: warmed,
      firstImport: !hadSnapshot,
    );
    // 刻意留的取证痕迹（同 `[prefetch]` 那套）：`adb logcat -s flutter` 能看到每次启动
    // 这一轮到底导进去了多少、新增多少、哪个标签失败了。
    debugPrint(
      '[library] 导入完成 · 落盘 ${report.dramas} 部'
      ' · 新增 $added 部${report.firstImport ? '（首次，没有上一份快照）' : ''}'
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
  /// 每张约 24 KB，合计约 8.6 MB（见 ADR-0008）。缓存的对象数上限要盖过这 360 张，
  /// 否则刚热完就有约 160 张被 LRU 挤掉——见 [CoverCacheManager]。
  Future<int> _warmCovers(List<String> urls) async {
    if (urls.isEmpty) return 0;
    final manager = CoverCacheManager();
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
