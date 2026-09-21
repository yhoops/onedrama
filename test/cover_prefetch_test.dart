import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/ui/cover_prefetch.dart';
import 'package:onedrama/ui/widgets/drama_card.dart';

void main() {
  group('封面 Hero 标签', () {
    test('带作用域：不同页面 / 不同标签页不会撞同一个标签', () {
      // 首页是 PageView、榜单是 TabBarView，滑动时相邻两页同时在树里，而它们的内容
      // 高度重叠。同标签出现两个 Hero，Flutter 会抛「multiple heroes that share the
      // same tag within a subtree」，所以作用域必须先不同。
      expect(coverHeroTag('t0', 'a'), isNot(coverHeroTag('t1', 'a')));
      expect(
        coverHeroTag('rank:hot', 'a'),
        isNot(coverHeroTag('rank:real', 'a')),
      );
      expect(coverHeroTag('search', 'a'), isNot(coverHeroTag('mine', 'a')));
      // 而同一处必须是同一个字符串——不然封面根本不会飞。
      expect(coverHeroTag('t0', 'a'), coverHeroTag('t0', 'a'));
    });
  });

  group('封面解码宽度', () {
    test('列表行那一档按最大的一行算得下，且确实比网格那一档小', () {
      const widestRowDp = 68; // 搜索结果行，几种行里最宽的
      const devicePixelRatio = 3; // xxhdpi
      expect(
        rowCoverWidth,
        greaterThanOrEqualTo((widestRowDp * devicePixelRatio).ceil()),
      );
      // 比网格那一档小才有意义——这个差值就是省下来的内存。
      expect(rowCoverWidth, lessThan(gridCoverWidth));
    });
  });

  group('预取窗口', () {
    testWidgets('只取前缘之后的一段、越界跳过、同一地址不重排', (tester) async {
      final prefetcher = CoverPrefetcher(
        memCacheWidth: rowCoverWidth,
        window: 4,
        concurrent: 2,
      );

      // 构建到第 1 条：窗口 = 2..5，但只有 2、3 在范围内。
      prefetcher.advanceTo(1, (index) => index <= 3 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u2', 'u3']);

      // 前缘推到第 2 条：补上 4（2、3 排过了）。
      prefetcher.advanceTo(2, (index) => index <= 4 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u2', 'u3', 'u4']);

      // 前缘后退（往回滑）：不重排，只是补上先前甩太快跳过的 1。
      prefetcher.advanceTo(0, (index) => index <= 4 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u2', 'u3', 'u4', 'u1']);

      // 原地再报一次：一个都不新增。
      prefetcher.advanceTo(1, (index) => index <= 3 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u2', 'u3', 'u4', 'u1']);

      // 页面走掉之后不再排队。
      prefetcher.dispose();
      prefetcher.advanceTo(3, (index) => index <= 9 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u2', 'u3', 'u4', 'u1']);
    });
  });
}
