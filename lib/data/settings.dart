import 'dart:convert';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观偏好。见参考页「设置 → 主题」。
enum ThemePreference { system, light, dark }

/// 播放器控制栏停在哪一侧。参考页的设置项叫「控制栏位置」。
enum ControlSide { left, right }

/// 手势灵敏度。参考页的「手势灵敏度：低 / 中 / 高」。
enum GestureSensitivity { low, medium, high }

/// 全部用户设置。不可变；改动通过 copyWith 生成新值再落盘。
class AppSettings {
  const AppSettings({
    this.theme = ThemePreference.system,
    this.largeText = false,
    this.defaultSpeed = 1.0,
    this.preferredQuality = 0,
    this.autoPlayNext = true,
    this.rememberProgress = true,
    this.controlSide = ControlSide.right,
    this.gestureSensitivity = GestureSensitivity.medium,
    this.hapticFeedback = true,
  });

  final ThemePreference theme;

  /// 大字模式。
  final bool largeText;

  /// 默认倍速。
  final double defaultSpeed;

  /// 优先画质；0 表示自动。数值约等于高度（720 / 1080）。
  final int preferredQuality;

  final bool autoPlayNext;

  /// 记忆播放进度。关掉就不再写 [WatchProgress]。
  final bool rememberProgress;

  final ControlSide controlSide;
  final GestureSensitivity gestureSensitivity;
  final bool hapticFeedback;

  AppSettings copyWith({
    ThemePreference? theme,
    bool? largeText,
    double? defaultSpeed,
    int? preferredQuality,
    bool? autoPlayNext,
    bool? rememberProgress,
    ControlSide? controlSide,
    GestureSensitivity? gestureSensitivity,
    bool? hapticFeedback,
  }) => AppSettings(
    theme: theme ?? this.theme,
    largeText: largeText ?? this.largeText,
    defaultSpeed: defaultSpeed ?? this.defaultSpeed,
    preferredQuality: preferredQuality ?? this.preferredQuality,
    autoPlayNext: autoPlayNext ?? this.autoPlayNext,
    rememberProgress: rememberProgress ?? this.rememberProgress,
    controlSide: controlSide ?? this.controlSide,
    gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
    hapticFeedback: hapticFeedback ?? this.hapticFeedback,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'theme': theme.name,
    'largeText': largeText,
    'defaultSpeed': defaultSpeed,
    'preferredQuality': preferredQuality,
    'autoPlayNext': autoPlayNext,
    'rememberProgress': rememberProgress,
    'controlSide': controlSide.name,
    'gestureSensitivity': gestureSensitivity.name,
    'hapticFeedback': hapticFeedback,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    theme:
        _enumByName(ThemePreference.values, json['theme']) ??
        ThemePreference.system,
    largeText: json['largeText'] as bool? ?? false,
    defaultSpeed: (json['defaultSpeed'] as num?)?.toDouble() ?? 1.0,
    preferredQuality: (json['preferredQuality'] as num?)?.toInt() ?? 0,
    autoPlayNext: json['autoPlayNext'] as bool? ?? true,
    rememberProgress: json['rememberProgress'] as bool? ?? true,
    controlSide:
        _enumByName(ControlSide.values, json['controlSide']) ??
        ControlSide.right,
    gestureSensitivity:
        _enumByName(GestureSensitivity.values, json['gestureSensitivity']) ??
        GestureSensitivity.medium,
    hapticFeedback: json['hapticFeedback'] as bool? ?? true,
  );
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// 设置与设备号。
///
/// 放 prefs 而不是数据库：都是小标量，而且是启动时**最早**需要的——设备号必须在
/// 第一个请求之前就位。
class SettingsStore {
  SettingsStore(this._prefs);

  static const String _keySettings = 'app_settings';
  static const String _keyDeviceId = 'hongguo_device_id';
  static const String _keyInstallId = 'hongguo_install_id';

  final SharedPreferences _prefs;

  /// 同一份 prefs 实例。给别的「小、整块、可重建」的本地副本用（如
  /// `RankingCache`）——`SharedPreferences.getInstance()` 本来就是单例，再开一次
  /// 只是多一层异步，不如从这里拿。
  SharedPreferences get prefs => _prefs;

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  AppSettings settings() {
    final raw = _prefs.getString(_keySettings);
    if (raw == null) return const AppSettings();
    final decoded = decodeJsonObject(raw);
    return decoded == null
        ? const AppSettings()
        : AppSettings.fromJson(decoded);
  }

  Future<void> saveSettings(AppSettings value) =>
      _prefs.setString(_keySettings, jsonEncode(value.toJson()));

  /// 设备号。**只生成一次后持久化**——每次重启都换会让服务端风控变脏。
  String deviceId() => _persisted(_keyDeviceId);

  String installId() => _persisted(_keyInstallId);

  /// 重新生成设备号。设置页的「剧库与存储」用它——代价是会换一套推荐。
  Future<void> regenerateDevice() async {
    await _prefs.setString(_keyDeviceId, newDeviceId());
    await _prefs.setString(_keyInstallId, newDeviceId());
  }

  String _persisted(String key) {
    final existing = _prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = newDeviceId();
    // 同步落盘即可，这里不 await——调用方拿到的值已经是对的。
    _prefs.setString(key, generated);
    return generated;
  }
}
