import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/library_importer.dart';
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

  group('导入结果', () {
    test('部数只算成功的标签，-1 与空标签都不计入', () {
      const report = LibraryImportReport(
        counts: {0: 90, 1: 90, 2: -1, 3: 0},
        coversWarmed: 12,
      );

      expect(report.dramas, 180);
      expect(report.failedTabs, 1);
      expect(report.ok, isFalse);
    });

    test('四个标签全成功才算 ok', () {
      const report = LibraryImportReport(
        counts: {0: 90, 1: 90, 2: 90, 3: 90},
        coversWarmed: 0,
      );
      expect(report.ok, isTrue);
      expect(report.failedTabs, 0);
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
