import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../theme.dart';

/// 统一的可点面：按下缩一点 + 可选震动。
///
/// **为什么不是 InkWell**：水波纹要有个 `Material` 祖先才看得见，而这些位置大多是
/// 「不透明 `Container` 上的 `GestureDetector`」——把不透明底色压在 ink 层上，波纹就
/// 被盖住了（设置页的 `_Section` 正是这个毛病）。缩放只需要动自己，跟祖先无关，
/// 在深色卡片上也不会有波纹那种「一块亮斑」的突兀感。
///
/// 手感统一在 [OneDramaSizes.pressScale] / [OneDramaSizes.pressDuration]，有意压在
/// 110ms 内：短剧 App 的页面很轻，回弹、弹性那类重动效反而显得廉价。
class Pressable extends ConsumerStatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = OneDramaSizes.pressScale,
    this.behavior = HitTestBehavior.opaque,
    this.haptic = true,
    this.semanticLabel,
  });

  final Widget child;

  /// null 表示这一处不可点（比如忙碌中），此时不做任何反馈。
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 缩放幅度。整行/整卡的按压用默认值；小 chip 可以浅一点。
  final double scale;

  final HitTestBehavior behavior;

  /// 是否允许震动。默认允许，但**必须**再过一遍设置里的「触感反馈」开关——
  /// 那个开关既然在设置页摆着，就不能有绕过它的路径。
  final bool haptic;

  final String? semanticLabel;

  @override
  ConsumerState<Pressable> createState() => _PressableState();
}

class _PressableState extends ConsumerState<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    final onTap = widget.onTap;
    if (onTap == null) return;
    if (widget.haptic && ref.read(settingsProvider).hapticFeedback) {
      // 最轻的一档：密集点选（题材 chip、选集宫格）时不至于吵。
      HapticFeedback.selectionClick();
    }
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    Widget child = AnimatedScale(
      scale: enabled && _pressed ? widget.scale : 1,
      duration: OneDramaSizes.pressDuration,
      curve: Curves.easeOut,
      child: widget.child,
    );

    final label = widget.semanticLabel;
    if (label != null) {
      child = Semantics(button: true, label: label, child: child);
    }

    return GestureDetector(
      behavior: widget.behavior,
      onTap: enabled ? _handleTap : null,
      onLongPress: enabled ? widget.onLongPress : null,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      child: child,
    );
  }
}
