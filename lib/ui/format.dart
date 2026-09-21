/// 数字的展示格式化。
///
/// 口径**照搬上游实测**，不是自己拍的：
///
/// | 字段 | 上游原样 | 规则 |
/// | --- | --- | --- |
/// | 热度 | `hot_score 42033495` → `4203万热度` | **整数万**，截断，无小数 |
/// | 热度（榜单 `heatText`） | `94677019` → `9467万热度` | 同上 |
/// | 计数类 | `33371` → `3.3万人评分`；`2506000` → `250.6万` | **截断到 1 位小数** |
///
/// 两处都是**截断**不是四舍五入：`94677019` 给 `9467万`，不是 9468。
///
/// 「热度用整数、计数用一位小数」是上游自己的分歧（热度的小数形式没有先例），这里如实
/// 照搬，不擅自统一——将来数字对不上时才能一眼归因到是哪一边。
///
/// 整数输入一律走**整数除法**取整：`value / 10000` 那种浮点写法在 `2506000` 这类值上
/// 可能落到 `2505.9999…`，`floor` 之后就成了 `250.5`，比上游少一位。
library;

/// 量级：`4203万` / `1.2亿` 这种已经在文本里的数量级。
final RegExp _magnitude = RegExp(r'(\d+(?:\.\d+)?)\s*([万亿])');

/// 抠出文本里的第一个数字。上游有把数字包在话术里的（`红果热度值4203万`）。
final RegExp _digits = RegExp(r'\d+(?:\.\d+)?');

const int _wan = 10000;
const int _yi = 100000000;

/// 截断到单位的整数倍。`42033495` + 万 → `4203`。
String _wholeMagnitude(num magnitude, int unit) => '${magnitude ~/ unit}';

/// 截断到一位小数。`2977018` + 万 → `297.7`；`2506000` → `250.6`；`10000` → `1`。
String _oneDecimal(num value, int unit) {
  final magnitude = value.abs();
  final whole = magnitude ~/ unit;
  final tenth = (magnitude % unit) * 10 ~/ unit;
  return tenth == 0 ? '$whole' : '$whole.$tenth';
}

/// 计数类：`2977018` → `297.7万`；`9532` → `9532`。
String compactCount(num value) {
  final magnitude = value.abs();
  if (magnitude >= _yi) return '${_oneDecimal(magnitude, _yi)}亿';
  if (magnitude >= _wan) return '${_oneDecimal(magnitude, _wan)}万';
  return value.round().toString();
}

/// 热度量级：**整数万**，截断。`42033495` → `4203万`。
String compactHeat(num value) {
  final magnitude = value.abs();
  if (magnitude >= _yi) return '${_wholeMagnitude(magnitude, _yi)}亿';
  if (magnitude >= _wan) return '${_wholeMagnitude(magnitude, _wan)}万';
  return value.round().toString();
}

/// 通用的「数量 + 后缀」渲染。
///
/// 上游已经给了量级（`4203万`）就沿用量级，只统一后缀——这样同一个数字不会因为我们
/// 自己重算而与上游差一位。认不出来的文本原样返回，宁可显示得朴素，也不要丢信息。
String _quantity(
  String raw, {
  required String suffix,
  required String Function(num) magnitude,
}) {
  final text = raw.trim();
  if (text.isEmpty) return '';

  final existing = _magnitude.firstMatch(text);
  if (existing != null) return '${existing.group(1)}${existing.group(2)}$suffix';

  final value = num.tryParse(_digits.firstMatch(text)?.group(0) ?? '');
  if (value == null) return text;
  return '${magnitude(value)}$suffix';
}

/// 热度。`42033495` → `4203万热度`；上游已给文本（`4203万热度` / `红果热度值4203万`）
/// 就沿用它的量级。
String heatLabel(String raw) =>
    _quantity(raw, suffix: '热度', magnitude: compactHeat);

/// 观看人数。`2977018` → `297.7万人看过`。
///
/// 上游**没有**任何格式化好的播放量（App 只给裸整数，网页压根不给），所以这个后缀与
/// 小数位是本项目按上游计数类的口径合成的。
String viewsLabel(String raw) =>
    _quantity(raw, suffix: '人看过', magnitude: compactCount);

/// 评分。`9.2` → `9.2分`；`9` → `9.0分`（上游网页就是 `评分9.0` 这种一位小数）。
String scoreLabel(String raw) {
  final value = num.tryParse(_digits.firstMatch(raw.trim())?.group(0) ?? '');
  if (value == null) return raw.trim();
  return '${value.toDouble().toStringAsFixed(1)}分';
}
