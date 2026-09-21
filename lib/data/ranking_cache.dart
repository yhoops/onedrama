import 'dart:convert';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 榜单的「上次成功结果」。
///
/// 为什么落盘：榜单页原来每次进来都重新拉，而红果榜单在两种渲染之间摇摆——约一半的
/// 请求拿不到数据（见 `parseRanking` 的注释）。全失败时能退回上一次的结果，比给一个
/// 错误页有用；顺带还换来「进页面 0 等待先看到旧榜、再后台刷新」。
///
/// 只存第 1 页：榜单 20 条一页、`totalPages` 上限 500，全存会把 prefs 撑大；而下拉翻到
/// 的第 3 页并不值得为「下次打开立刻可见」付这份体积。
///
/// 这里存的是**展示用**的数据（名次 / 热度文字 / 剧快照），不参与协议解析，所以与
/// `ADR-0003`（Go 是协议真相）无关。
class RankingCache {
  RankingCache(this._prefs);

  static const String _keyPrefix = 'ranking_cache_';

  final SharedPreferences _prefs;

  static String _keyOf(String boardId) => '$_keyPrefix$boardId';

  /// 读上次的结果。没有、坏了、读不出条目一律当没有——缓存坏掉不该让页面报错。
  CachedRanking? read(String boardId) {
    final raw = _prefs.getString(_keyOf(boardId));
    if (raw == null || raw.isEmpty) return null;
    final decoded = decodeJsonObject(raw);
    if (decoded == null) return null;

    final stamp = (decoded['updatedAt'] as num?)?.toInt() ?? 0;
    if (stamp <= 0) return null;

    final items = <RankingItem>[];
    for (final entry in anyList(decoded['items'])) {
      if (entry is! Map<String, dynamic>) continue;
      final drama = entry['drama'];
      items.add(
        RankingItem(
          rank: (entry['rank'] as num?)?.toInt() ?? 0,
          metric: entry['metric'] as String? ?? '',
          drama: drama is Map<String, dynamic>
              ? Drama.fromJson(drama)
              : const Drama(),
        ),
      );
    }
    if (items.isEmpty) return null;

    return CachedRanking(
      items: items,
      totalPages: (decoded['totalPages'] as num?)?.toInt() ?? 1,
      updatedText: decoded['updatedText'] as String? ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(stamp),
    );
  }

  /// 记下第一页。只有第 1 页值得留，所以别的页码直接不写。
  Future<void> write(String boardId, RankingPage page) async {
    if (page.page != 1 || page.items.isEmpty) return;
    final payload = <String, Object?>{
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'totalPages': page.totalPages,
      'updatedText': page.updatedText,
      'items': [
        for (final item in page.items)
          <String, Object?>{
            'rank': item.rank,
            'metric': item.metric,
            'drama': item.drama.toJson(),
          },
      ],
    };
    await _prefs.setString(_keyOf(boardId), jsonEncode(payload));
  }

  /// 清掉全部榜单缓存，返回清掉的榜数。设置页的「清除缓存」与它连在一起
  /// （见 `docs/plan.md` 阶段 4）：清缓存应当把可重建的本地副本都清掉。
  Future<int> clear() async {
    final keys = _prefs
        .getKeys()
        .where((key) => key.startsWith(_keyPrefix))
        .toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
    return keys.length;
  }
}

/// 缓存的榜单一页。语义是「上次成功取到的第 1 页」。
class CachedRanking {
  const CachedRanking({
    required this.items,
    required this.totalPages,
    required this.updatedText,
    required this.updatedAt,
  });

  final List<RankingItem> items;
  final int totalPages;
  final String updatedText;
  final DateTime updatedAt;
}
