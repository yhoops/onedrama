import 'package:flutter/material.dart';

import '../theme.dart';

/// 路由转场：新页淡入 + 上移，旧页静止。
///
/// **为什么不用系统的 `FadeForwardsPageTransitionsBuilder`**（M3 在 Android 上的默认、
/// 这一版之前用的就是它）：它是 **450ms**、旧页横滑 **-25%** 并在前 25% 里淡出、新页横滑
/// **+25%** 并淡入（SDK `material/page_transitions_theme.dart` 的 `kTransitionMilliseconds`
/// 与三个 `Animatable`）。横向大位移 + 450ms 是 M3 里最重的一档；而这个 App 的底栏切页是
/// 130ms 淡入 + 上移 10px（`home_shell.dart`）。两套语汇摆在一起，跳转就显得比别人家硬。
/// 顺带纠一处**注释与实现不符**：那一版 `theme.dart` 上写着「淡入淡出 + 轻微上移」，
/// 而系统那套是横向滑 25%，根本没往上移。
///
/// 这里做三件事，两个数字都收在 [OneDramaSizes] 里：
///
/// 1. 新页 `opacity 0→1`，同时上移 [OneDramaSizes.routeFadeOffset]；
/// 2. **旧页一动不动**——基类的 `delegatedTransition` 默认返回 null
///    （SDK `widgets/page_transitions_builder.dart`），不重写它，旧页就完全不参与动画。
///    屏幕上的主运动于是永远落在「正在进出的那一页」上，不会两页一起乱动；
/// 3. 时长走 `transitionDuration`（基类默认 300ms，这里压到 180ms）——`MaterialRouteTransitionMixin`
///    会读它（SDK `material/page.dart`），而 **Hero 的飞行是由路由动画本身驱动的**：
///    `widgets/heroes.dart` 里 `_proxyAnimation.parent = manifest.animation`，没有独立时长。
///    所以封面飞行会自动跟着变成 180ms，转场与飞行不会各跑各的。
///
/// 返回（pop）天然镜像：路由的 animation 反向走 1→0，同一段代码就让关闭页淡出 + 下移，
/// 露出的那一页仍然静止。
///
/// 转场期间**不需要**铺背景色。系统的 FadeForwards 要铺是因为它两页都在淡、中间会透出底；
/// 这里旧页始终不透明且不动，新页只是在它上面淡入，没有穿透的机会。
class FadeUpPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeUpPageTransitionsBuilder();

  @override
  Duration get transitionDuration => OneDramaSizes.routeFadeDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final progress = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return AnimatedBuilder(
      animation: progress,
      // child 原样传进来：转场只动 opacity 与位移，不重建页面。
      child: child,
      builder: (context, child) {
        final value = progress.value;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            // 用像素位移而不是 `SlideTransition` 的分数偏移：12px 是个绝对量，
            // 换成页高的百分比会在不同屏幕上时大时小。
            offset: Offset(0, (1 - value) * OneDramaSizes.routeFadeOffset),
            child: child,
          ),
        );
      },
    );
  }
}
