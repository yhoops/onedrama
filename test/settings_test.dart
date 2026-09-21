import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/data/settings.dart';

/// 设置的落盘往返。
///
/// 这一层很容易漏：加一个字段要同时改构造函数、`copyWith`、`toJson`、`fromJson` 四处，
/// 漏掉任何一处都是**静默**的——`copyWith` 漏了是「改了不生效」，`toJson`/`fromJson` 漏了
/// 是「重启就变回默认」。设置页每一项都声称真的接线，所以这条值得钉住。
void main() {
  group('设置往返', () {
    test('每个开关都能改、能落盘、能读回来', () {
      const defaults = AppSettings();

      final changed = defaults.copyWith(
        theme: ThemePreference.dark,
        largeText: true,
        defaultSpeed: 1.5,
        preferredQuality: 720,
        autoPlayNext: false,
        rememberProgress: false,
        prefetchNext: false,
        controlSide: ControlSide.left,
        gestureSensitivity: GestureSensitivity.high,
        hapticFeedback: false,
      );

      // 真的变了，而不是 copyWith 漏掉了某个字段。
      expect(changed.theme, ThemePreference.dark);
      expect(changed.largeText, isTrue);
      expect(changed.defaultSpeed, 1.5);
      expect(changed.preferredQuality, 720);
      expect(changed.autoPlayNext, isFalse);
      expect(changed.rememberProgress, isFalse);
      expect(changed.prefetchNext, isFalse);
      expect(changed.controlSide, ControlSide.left);
      expect(changed.gestureSensitivity, GestureSensitivity.high);
      expect(changed.hapticFeedback, isFalse);

      final restored = AppSettings.fromJson(changed.toJson());
      expect(restored.theme, changed.theme);
      expect(restored.largeText, changed.largeText);
      expect(restored.defaultSpeed, changed.defaultSpeed);
      expect(restored.preferredQuality, changed.preferredQuality);
      expect(restored.autoPlayNext, changed.autoPlayNext);
      expect(restored.rememberProgress, changed.rememberProgress);
      expect(restored.prefetchNext, changed.prefetchNext);
      expect(restored.controlSide, changed.controlSide);
      expect(restored.gestureSensitivity, changed.gestureSensitivity);
      expect(restored.hapticFeedback, changed.hapticFeedback);
    });

    test('旧版本的存档缺字段时退回默认值，不是崩或 false', () {
      // 上一版落盘的那份里没有 prefetchNext——默认必须是**开**，否则升级上来的用户
      // 会莫名其妙没有预取。
      final legacy = AppSettings.fromJson(<String, dynamic>{
        'theme': 'dark',
        'autoPlayNext': false,
      });

      expect(legacy.theme, ThemePreference.dark);
      expect(legacy.autoPlayNext, isFalse);
      expect(legacy.prefetchNext, isTrue);
      expect(legacy.rememberProgress, isTrue);
      expect(legacy.controlSide, ControlSide.right);
    });
  });
}
