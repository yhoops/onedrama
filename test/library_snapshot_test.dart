import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/library_importer.dart';
import 'package:onedrama/data/library_tabs.dart';
import 'package:onedrama/ui/library_page.dart';

/// 剧库快照并进首页列表的那条规则（`docs/adr/0008`）。
///
/// 这条规则写反了很隐蔽：插到尾部时首页看上去一切正常，只是新剧永远排在几十部快照
/// 之后，没人滑得到。所以钉住方向。
void main() {
  Drama drama(String id) => Drama(id: id);

  group('并进列表', () {
    test('头部检查：新剧插到最前，已有的一部不动', () {
      final into = [drama('a'), drama('b'), drama('c')];

      final added = absorbDramas(
        into,
        [drama('new1'), drama('a'), drama('new2')],
        atTop: true,
      );

      expect(added, 2);
      expect(into.map((d) => d.id), ['new1', 'new2', 'a', 'b', 'c']);
    });

    test('向后翻页：新剧接在最后', () {
      final into = [drama('a'), drama('b')];

      final added = absorbDramas(
        into,
        [drama('b'), drama('c'), drama('d')],
        atTop: false,
      );

      expect(added, 2);
      expect(into.map((d) => d.id), ['a', 'b', 'c', 'd']);
    });

    test('整页都是已有的：一条都不插，也不重排', () {
      final into = [drama('a'), drama('b')];

      expect(absorbDramas(into, [drama('b'), drama('a')], atTop: true), 0);
      expect(into.map((d) => d.id), ['a', 'b']);
    });

    test('同一页里自己重复的也只留一条', () {
      final into = <Drama>[];
      expect(absorbDramas(into, [drama('a'), drama('a')], atTop: true), 1);
      expect(into.map((d) => d.id), ['a']);
    });

    test('没有 ID 的条目直接丢掉', () {
      final into = <Drama>[];
      expect(absorbDramas(into, [drama(''), drama('a')], atTop: true), 1);
      expect(into.map((d) => d.id), ['a']);
    });

    test('空的一页什么都不做', () {
      final into = [drama('a')];
      expect(absorbDramas(into, const <Drama>[], atTop: true), 0);
      expect(into.map((d) => d.id), ['a']);
    });
  });

  /// 「剧库部数与本次新增只算分类标签」这条口径的支点。综合要是被算进来，那个数字
  /// 会常年顶在几十部而上游一部没上（见 `CONTEXT.md` 的 Library Count / Newly Added）。
  group('分类标签', () {
    test('综合不算分类标签，另外三个算', () {
      expect(libraryTabs.first.label, '综合');
      expect(libraryTabs.first.isCategory, isFalse);
      expect(categoryTabIndexes, [1, 2, 3]);
    });

    test('分类标签都有 genreKey——少了它就走不了分类接口', () {
      for (final index in categoryTabIndexes) {
        expect(libraryTabs[index].genreKey, isNotNull, reason: '下标 $index');
        expect(libraryTabs[index].scene, isNotNull, reason: '下标 $index');
      }
    });
  });

  group('导入结果', () {
    test('落盘部数只算成功的标签，-1 与空标签都不计入', () {
      const report = LibraryImportReport(
        counts: {0: 90, 1: 90, 2: -1, 3: 0},
        added: 7,
        coversWarmed: 12,
        firstImport: false,
      );

      expect(report.dramas, 180);
      expect(report.failedTabs, 1);
      expect(report.ok, isFalse);
    });

    test('四个标签全成功才算 ok', () {
      const report = LibraryImportReport(
        counts: {0: 90, 1: 90, 2: 90, 3: 90},
        added: 0,
        coversWarmed: 0,
        firstImport: false,
      );
      expect(report.ok, isTrue);
      expect(report.failedTabs, 0);
    });
  });

  /// 更新完成那条 SnackBar 的文案。三条分支写反了都不会报错，只会表现成
  /// 「弹窗说的数不对」——要到用户抱怨时才发现，所以钉住。
  group('更新完成弹窗', () {
    LibraryImportReport report({
      Map<int, int> counts = const {0: 90, 1: 90, 2: 90, 3: 90},
      int added = 12,
      bool firstImport = false,
    }) => LibraryImportReport(
      counts: counts,
      added: added,
      coversWarmed: 0,
      firstImport: firstImport,
    );

    test('正常一轮：本次新增与剧库总部数', () {
      expect(
        importToast(report(), libraryCount: 267),
        '本次新增 12 部，剧库共 267 部',
      );
    });

    test('部分失败：点明那个数为什么偏低', () {
      expect(
        importToast(
          report(counts: const {0: 90, 1: -1, 2: 90, 3: 90}),
          libraryCount: 180,
        ),
        '本次新增 12 部，剧库共 180 部 · 1 个标签没更新上，保留了旧数据',
      );
    });

    test('首次导入全部成功：不弹——那时「新增」就是全部部数', () {
      expect(importToast(report(firstImport: true), libraryCount: 270), isNull);
    });

    test('首次导入部分失败：说清导进去多少、几个没拉成', () {
      expect(
        importToast(
          report(counts: const {0: 90, 1: -1, 2: 90, 3: 90}, firstImport: true),
          libraryCount: 180,
        ),
        '首次导入 180 部 · 1 个标签没拉成',
      );
    });

    test('首次导入全挂：那一行会停在「尚未更新」，必须说一句', () {
      expect(
        importToast(
          report(counts: const {0: -1, 1: -1, 2: -1, 3: -1}, firstImport: true),
          libraryCount: 0,
        ),
        '4 个标签都没拉成，本地还没有剧库数据',
      );
    });

    test('首次导入全挂但综合进来了：部数仍是 0，不能报「首次导入 90 部」', () {
      // 综合落了 90 行，可它不进剧库部数——分类标签一部都没有。
      expect(
        importToast(
          report(counts: const {0: 90, 1: -1, 2: -1, 3: -1}, firstImport: true),
          libraryCount: 0,
        ),
        '3 个标签都没拉成，本地还没有剧库数据',
      );
    });
  });

  group('导入进度文案', () {
    test('两个阶段各自的说法', () {
      expect(
        const LibraryImportProgress(
          stage: LibraryImportStage.catalog,
          done: 12,
          total: 20,
        ).label,
        '导入剧库 12/20',
      );
      expect(
        const LibraryImportProgress(
          stage: LibraryImportStage.covers,
          done: 88,
          total: 360,
        ).label,
        '缓存封面 88/360',
      );
    });
  });
}
