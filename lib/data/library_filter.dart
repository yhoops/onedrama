/// 短剧库信息流的**本地**筛选 + 排序，叠在已加载的 `dramas` 之上。
///
/// 题材筛选走服务端（`CatalogPager.filterRoute` / `HongguoCatalogApi`），**不在这里**——
/// 这里只处理「状态·篇幅」与「排序」这类服务端给不了、或只对已加载结果有意义的口径
/// （见任务 09-27-tag-filter：图里「按已加载短剧排序，缺少数据的短剧排在最后」）。
library;

import 'package:hongguo_dart/hongguo_dart.dart';

/// 完结状态过滤。`releaseStatus` 的规范值是 `ongoing` / `finished`（见
/// `releaseStatusFromRemark`），空或 `unknown` 两个都不匹配。
enum LibraryStatus { any, ongoing, finished }

/// 排序口径。`none` = 保持服务端/已加载的原始顺序。
enum LibrarySort { none, latest, heat, views, title, fewestEpisodes }

/// 集数：优先 `episodeCount`，回落 `totalEpisode`；都解不出返回 null。
int? _episodes(Drama d) =>
    int.tryParse(d.episodeCount.trim()) ?? int.tryParse(d.totalEpisode.trim());

/// 先按 [status] / [withinSixty] 过滤，再按 [sort] 排序。
///
/// **缺少数据的短剧排在最后**是刻意口径：网页源的剧没有热度/播放量、也可能没有上线日期，
/// 按这些排时把它们沉底，而不是当 0 混进正常值里骗人。排序对「有键」的项用稳定排序
/// （原序做 tiebreaker），"没键" 的项保持原序接在后面。
///
/// 抽成顶层纯函数以便单测——过滤/排序写反了不报错，只表现成很隐蔽的「列表顺序不对」。
List<Drama> applyLibraryFilters(
  List<Drama> src, {
  LibraryStatus status = LibraryStatus.any,
  bool withinSixty = false,
  LibrarySort sort = LibrarySort.none,
}) {
  final filtered = <Drama>[];
  for (final drama in src) {
    if (status == LibraryStatus.ongoing && drama.releaseStatus != 'ongoing') {
      continue;
    }
    if (status == LibraryStatus.finished && drama.releaseStatus != 'finished') {
      continue;
    }
    if (withinSixty) {
      final count = _episodes(drama);
      if (count == null || count > 60) continue;
    }
    filtered.add(drama);
  }

  switch (sort) {
    case LibrarySort.none:
      return filtered;
    case LibrarySort.latest:
      return _sortMissingLast<String>(
          filtered, (d) => d.onlineDate.trim().isEmpty ? null : d.onlineDate.trim(),
          desc: true);
    case LibrarySort.heat:
      return _sortMissingLast<num>(filtered, (d) => int.tryParse(d.heat.trim()),
          desc: true);
    case LibrarySort.views:
      return _sortMissingLast<num>(filtered, (d) => int.tryParse(d.views.trim()),
          desc: true);
    case LibrarySort.title:
      return _sortMissingLast<String>(
          filtered, (d) => d.title.trim().isEmpty ? null : d.title.trim());
    case LibrarySort.fewestEpisodes:
      return _sortMissingLast<num>(filtered, _episodes);
  }
}

/// 有 [key] 的项按 key 排（[desc] 决定升降、原序做 tiebreaker 保稳定），
/// key 为 null 的项保持原序接在最后。
List<Drama> _sortMissingLast<T extends Comparable<Object>>(
  List<Drama> items,
  T? Function(Drama) key, {
  bool desc = false,
}) {
  final withKey = <(int, Drama)>[];
  final without = <Drama>[];
  for (var i = 0; i < items.length; i++) {
    final k = key(items[i]);
    if (k == null) {
      without.add(items[i]);
    } else {
      withKey.add((i, items[i]));
    }
  }
  withKey.sort((a, b) {
    final compare = key(a.$2)!.compareTo(key(b.$2)!);
    if (compare != 0) return desc ? -compare : compare;
    return a.$1.compareTo(b.$1); // 原序 tiebreaker → 稳定
  });
  return <Drama>[for (final entry in withKey) entry.$2, ...without];
}
