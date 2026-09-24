/// 一个标签的分页状态机。
///
/// 首页的滚动加载与剧库导入**共用同一套游标规则**，理由与 [libraryTabs] 一样：两边各写
/// 一份的话，「综合走推荐、其余走分类」「session 30 分钟过期」「seen 最多 540 条」这些
/// 约束迟早只在一处生效。协议本身在 `hongguo_dart` 里已经守过一遍，这里是调用侧的口径。
library;

import 'package:flutter/foundation.dart';
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

  /// 这个标签已经**降级到网页源**了。
  ///
  /// 一旦 App 分类这条腿断在某一页上，本 pager 剩下的页全部走网页 `?page=N`，
  /// **不再回 App**。原因是两套坐标系不能混：App 是 `offset + session_id`，网页是
  /// 页码，混着走会让 `_offset` / `_cursor` 失去意义，症状是翻页重复或跳页。
  ///
  /// 只记在实例上、不落盘：下一次新建 pager（下次启动、或剧库导入那一轮）会**重新先试
  /// App**——上游恢复了就自动回来，不必手动干预。
  bool _webMode = false;
  int _webPage = 0;

  /// 上游说没有更多了。
  bool get exhausted => _exhausted;

  /// 已经拉到的剧 ID。综合那一支要用它让服务端去重。
  Set<String> get ids => _ids;

  /// 是否已降级到网页源。诊断用（同 `[warm]` / `[library]` 那套取证痕迹）。
  bool get degraded => _webMode;

  /// 拉下一页，返回其中**没见过的**那些（见过的已经在列表里了）。
  Future<List<Drama>> next() async {
    if (_exhausted) return const <Drama>[];

    final List<Drama> incoming;
    if (tab.genreKey == null) {
      // 综合走推荐接口。`seen` 让服务端去重，上限 540 是协议侧的硬上限。
      //
      // **没有兜底**：网页没有「推荐」这个等价物，所以 App 推荐接口一挂，综合就是挂。
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
    } else if (_webMode) {
      incoming = await _nextWebPage();
    } else {
      incoming = await _nextCategoryPage();
    }

    final fresh = <Drama>[];
    for (final drama in incoming) {
      if (drama.id.isEmpty || !_ids.add(drama.id)) continue;
      fresh.add(drama);
    }
    return fresh;
  }

  /// App 分类的一页。这条腿断掉时**整个标签**降级到网页，本 pager 之后不再回 App。
  Future<List<Drama>> _nextCategoryPage() async {
    try {
      final page = await client.fetchCatalogPage(
        genreKey: tab.genreKey!,
        scene: tab.scene!,
        category: tab.label,
        cursor: _cursor,
      );
      _cursor = page.cursor;
      _exhausted = page.cursor.exhausted;
      return page.dramas;
    } catch (error) {
      final route = tab.webRoute;
      if (route.isEmpty) rethrow;
      // **这是故意的**——上游已经出现过「接口还在但不再吐数据」的情况（App 详情就是
      // 200 + 空体），卡死在一次失败上，用户看到的是「这个标签永远转圈」。
      _webMode = true;
      _webPage = 0;
      // 取证痕迹：降级必须能从日志里看出来，否则「为什么这次列表少了播放量」只能靠猜
      // （网页分类不给播放量）。
      debugPrint('[degrade] ${tab.label} App 分类失败，转网页 ?page=N：$error');
      return _nextWebPage();
    }
  }

  /// 网页分类的一页。页码从 1 开始递增。
  ///
  /// `totalPages` 解析不出来时（返回 0）不当作到底，而是靠「这一页返回了 0 条」来收尾——
  /// 宁可多打一次请求，也别因为页面结构变了就以为翻完了。
  Future<List<Drama>> _nextWebPage() async {
    final page = await client.fetchWebCategoryPage(
      route: tab.webRoute,
      category: tab.label,
      page: _webPage + 1,
    );
    _webPage = page.page;
    _exhausted = page.dramas.isEmpty ||
        (page.totalPages > 0 && _webPage >= page.totalPages);
    return page.dramas;
  }
}
