import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史的条数上限。超了从**最老**那头挤掉。
const int searchHistoryLimit = 20;

/// 记一个词之后的新列表。
///
/// 规则两条：**重复的提到最前**、超上限的挤掉最老的。
///
/// 抽成顶层函数是为了能单测——顺序或截断写反都不会报错，只会表现成「历史怪怪的」，
/// 而归因要到用户抱怨时才发现。
List<String> pushSearchKeyword(List<String> current, String keyword) {
  final word = keyword.trim();
  if (word.isEmpty) return current;
  final next = <String>[word, ...current.where((item) => item != word)];
  return next.length > searchHistoryLimit
      ? next.sublist(0, searchHistoryLimit)
      : next;
}

/// 搜过的词（`CONTEXT.md` 的 Search History）。
///
/// 放 prefs 而不是建表：这是「小、整块、可重建」的一类，与设置、榜单缓存同一口径。
/// 顺序即「最近在前」，UI 直接照用。
class SearchHistoryStore {
  SearchHistoryStore(this._prefs);

  static const String _key = 'search_history';

  final SharedPreferences _prefs;

  List<String> entries() => _prefs.getStringList(_key) ?? const <String>[];

  Future<void> save(List<String> entries) =>
      _prefs.setStringList(_key, entries);

  Future<void> clear() => _prefs.remove(_key);
}
