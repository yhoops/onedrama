import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/ui/theme.dart';
import 'package:onedrama/ui/widgets/page_transition.dart';

const Key homeKey = Key('home');
const Key detailKey = Key('detail');

/// 转场里那一层「新页」的透明度。
///
/// `find.ancestor` 是**由近及远**走的（`visitAncestorElements` 从直接父节点往上），
/// 所以 `.first` 就是转场自己加的那层。
double? routeOpacity(WidgetTester tester, Key key) {
  final finder = find.ancestor(
    of: find.byKey(key),
    matching: find.byType(Opacity),
  );
  if (finder.evaluate().isEmpty) return null;
  return tester.widgetList<Opacity>(finder).first.opacity;
}

void main() {
  // 不需要覆写平台：SDK 写明「测试环境里 `defaultTargetPlatform` 一律是
  // `TargetPlatform.android`」（`foundation/platform.dart` 的 `defaultTargetPlatform`
  // 文档）。而主题里只给 android 配了转场——所以下面那条
  // `route.transitionDuration == 180ms` 同时也是「查到的确实是 android 那一档」的证据：
  // 查不到就会静默退回 Material 默认的 300ms，测试立刻红。

  test('时长取自 builder：180ms（换掉的那套系统 FadeForwards 是 450ms）', () {
    expect(
      const FadeUpPageTransitionsBuilder().transitionDuration,
      const Duration(milliseconds: 180),
    );
    expect(OneDramaSizes.routeFadeDuration, const Duration(milliseconds: 180));
  });

  test('不重写 delegatedTransition：旧页因此完全不参与动画', () {
    // 基类默认返回 null（`widgets/page_transitions_builder.dart:61`）。哪天有人「顺手」
    // 把它补上，旧页就会开始跟着动——这条测试专门拦那一下。
    expect(const FadeUpPageTransitionsBuilder().delegatedTransition, isNull);
  });

  testWidgets('真路由走一遍：90ms 时新页还半透明且低着，旧页一动不动', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        navigatorKey: navigator,
        home: const ColoredBox(key: homeKey, color: Colors.white),
      ),
    );
    final homeAtStart = tester.getTopLeft(find.byKey(homeKey));

    final route = MaterialPageRoute<void>(
      builder: (_) => const ColoredBox(key: detailKey, color: Colors.white),
    );
    navigator.currentState!.push(route);
    await tester.pump();

    // 这条是「主题里的 builder 真的被用上了」的证据：时长不是 Material 的 300ms，
    // 也不是系统 FadeForwards 的 450ms，而是这里配的 180ms。
    expect(route.transitionDuration, const Duration(milliseconds: 180));

    await tester.pump(const Duration(milliseconds: 90));
    // 新页：淡入没走完（半透明）。
    final midwayOpacity = routeOpacity(tester, detailKey);
    expect(midwayOpacity, isNotNull);
    expect(midwayOpacity!, greaterThan(0.0));
    expect(midwayOpacity, lessThan(1.0));
    // 新页：上移没走完（还低着）。
    expect(tester.getTopLeft(find.byKey(detailKey)).dy, greaterThan(0.0));
    // 旧页：一动没动。
    expect(tester.getTopLeft(find.byKey(homeKey)), homeAtStart);

    await tester.pump(const Duration(milliseconds: 120));
    // 走完：完全到位。
    expect(routeOpacity(tester, detailKey), 1.0);
    expect(tester.getTopLeft(find.byKey(detailKey)).dy, 0.0);
    // 此刻**不要**再去量旧页的位置：转场一结束，上面这条路由的 overlay entry 就变成了
    // `opaque = true`（`widgets/routes.dart:293`，转场期间它是 false），旧页随即变成
    // offstage，默认 finder 就找不到它了。上面第 73 行那条才是「旧页静止」的证据——
    // 而它之所以成立，正因为转场期间旧页仍然被绘制。
  });

  testWidgets('返回是对称的：关闭页淡出 + 下移，露出的那一页仍然静止', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        navigatorKey: navigator,
        home: const ColoredBox(key: homeKey, color: Colors.white),
      ),
    );
    // 趁首页还是唯一那条路由（onstage）先记下它的位置。
    final homeAtStart = tester.getTopLeft(find.byKey(homeKey));

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const ColoredBox(key: detailKey, color: Colors.white),
      ),
    );
    await tester.pumpAndSettle();

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    // 关闭页：半透明 + 已经往下移。
    final closingOpacity = routeOpacity(tester, detailKey);
    expect(closingOpacity, isNotNull);
    expect(closingOpacity!, lessThan(1.0));
    expect(tester.getTopLeft(find.byKey(detailKey)).dy, greaterThan(0.0));
    // 露出的那一页：静止。
    expect(tester.getTopLeft(find.byKey(homeKey)), homeAtStart);

    await tester.pumpAndSettle();
    // 收完之后首页仍然是那个位置（这时它已经重新 onstage）。
    expect(tester.getTopLeft(find.byKey(homeKey)), homeAtStart);
  });
}
