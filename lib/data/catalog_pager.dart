/// 一个标签的分页状态机。
///
/// 首页的滚动加载与剧库导入**共用同一套游标规则**，理由与 [libraryTabs] 一样：两边各写
/// 一份的话，「综合走推荐、其余走分类」「session 30 分钟过期」「seen 最多 540 条」这些
/// 约束迟早只在一处生效。协议本身在 `hongguo_dart` 里已经守过一遍，这里是调用侧的口径。
library;

import 'package:hongguo_dart/hongguo_dart.dart';

import 'library_tabs.dart';

class CatalogPager {
  CatalogPager({required this.client, required this.tab});

  final HongguoClient client;
  final LibraryTab tab;

  CatalogCursor _cursor = const CatalogCursor();
  int _offset = 0;
  String _sessionId = '';
  final Set<String> _ids = <String>{};

  bool _exhausted = false;

  /// 上游说没有更多了。
  bool get exhausted => _exhausted;

  /// 已经拉到的剧 ID。综合那一支要用它让服务端去重。
  Set<String> get ids => _ids;

  /// 拉下一页，返回其中**没见过的**那些（见过的已经在列表里了）。
  Future<List<Drama>> next() async {
    if (_exhausted) return const <Drama>[];

    final List<Drama> incoming;
    if (tab.genreKey == null) {
      // 综合走推荐接口。`seen` 让服务端去重，上限 540 是协议侧的硬上限。
      final page = await client.fetchRecommendations(
        RecommendationQuery(
          genre: 'short_play',
          offset: _offset,
          sessionId: _sessionId,
          seen: _ids.take(540).toList(),
        ),
      );
      _offset = page.nextOffset;
      _sessionId = page.sessionId;
      _exhausted = !page.hasMore;
      incoming = page.dramas;
    } else {
      final page = await client.fetchCatalogPage(
        genreKey: tab.genreKey!,
        scene: tab.scene!,
        category: tab.label,
        cursor: _cursor,
      );
      _cursor = page.cursor;
      _exhausted = page.cursor.exhausted;
      incoming = page.dramas;
    }

    final fresh = <Drama>[];
    for (final drama in incoming) {
      if (drama.id.isEmpty || !_ids.add(drama.id)) continue;
      fresh.add(drama);
    }
    return fresh;
  }
}
