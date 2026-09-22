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

  group('启动预热', () {
    testWidgets('warmFrom(0) 从第一张起热满一窗——含下标 0 本身', (tester) async {
      // 这条是它与 `advanceTo` 的关键差别：`advanceTo` 取的是「前缘**之后**」，传 0 会被
      // 理解成「构建到了第 0 条」而**跳过首屏第一张**。启动预热时还没有任何东西被构建过，
      // 漏掉第一张就是漏掉用户第一眼看的那张。
      final prefetcher = CoverPrefetcher(
        memCacheWidth: gridCoverWidth,
        window: CoverPrefetcher.firstScreen,
        concurrent: 2,
      );

      prefetcher.warmFrom(0, (index) => 'u$index');
      expect(prefetcher.debugQueued, ['u0', 'u1', 'u2', 'u3', 'u4', 'u5']);

      // 与滚动预取混用：去重是共享的，已经排过的不再排一次。
      prefetcher.advanceTo(3, (index) => index <= 9 ? 'u$index' : '');
      expect(prefetcher.debugQueued, [
        'u0',
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
        'u6',
        'u7',
        'u8',
        'u9',
      ]);
    });

    testWidgets('快照比一屏还短时越界跳过，不排空串', (tester) async {
      final prefetcher = CoverPrefetcher(memCacheWidth: gridCoverWidth);
      prefetcher.warmFrom(0, (index) => index < 2 ? 'u$index' : '');
      expect(prefetcher.debugQueued, ['u0', 'u1']);
    });

    test('预热的窗口比滚动预取小——只为「第一眼」，不是一屏半', () {
      expect(CoverPrefetcher.firstScreen, lessThan(CoverPrefetcher.defaultWindow));
    });
  });
}
