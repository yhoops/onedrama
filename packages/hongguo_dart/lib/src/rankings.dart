import 'dart:convert';

import 'client.dart';
import 'cover.dart';
import 'ids.dart';
import 'json.dart';
import 'web.dart';

/// 一个榜单。对照 Go 的 `RankingBoard`。
class RankingBoard {
  const RankingBoard({
    required this.id,
    required this.name,
    required this.description,
    required this.path,
    required this.upstreamKey,
  });

  final String id;
  final String name;
  final String description;
  final String path;
  final String upstreamKey;
}

const List<RankingBoard> rankingBoards = <RankingBoard>[
  RankingBoard(
    id: 'hongguo-hot',
    name: '总热播榜',
    description: '红果观看、互动等综合热度；每日更新。',
    path: 'hot-drama',
    upstreamKey: 'hongguo',
  ),
  RankingBoard(
    id: 'hongguo-real',
    name: '真人剧榜',
    description: '红果真人剧热播榜；每日更新。',
    path: 'hot-real-drama',
    upstreamKey: 'real',
  ),
  RankingBoard(
    id: 'hongguo-comic',
    name: '漫剧榜',
    description: '红果漫剧热播榜；每日更新。',
    path: 'hot-comic-drama',
    upstreamKey: 'comic',
  ),
  RankingBoard(
    id: 'hongguo-ai',
    name: 'AI剧榜',
    description: '红果 AI 剧热播榜；每日更新。',
    path: 'hot-ai-drama',
    upstreamKey: 'ai',
  ),
];

/// 榜单一条。对照 Go 的 `RankingItem`。
class RankingItem {
  const RankingItem({
    required this.rank,
    required this.drama,
    this.metric = '',
  });

  final int rank;
  final Drama drama;

  /// 榜面上的热度文字（`heatText`）。
  final String metric;
}

/// 榜单一页。对照 Go 的 `RankingPage`。
class RankingPage {
  const RankingPage({
    required this.boardId,
    required this.page,
    required this.items,
    required this.hasMore,
    this.totalPages = 0,
    this.updatedText = '',
  });

  final String boardId;
  final int page;
  final List<RankingItem> items;
  final bool hasMore;
  final int totalPages;
  final String updatedText;
}

/// 找榜单。对照 Go 的 `FindRankingBoard`。
RankingBoard? findRankingBoard(String id) {
  for (final board in rankingBoards) {
    if (board.id == id) return board;
  }
  return null;
}

/// 解析榜单一页。对照 Go 的 `ParseRanking`。
///
/// 固定 20 条一页，`rank` 必须落在本页区间且**严格递增**。站点悄悄改分页时，这些
/// 守卫是唯一能立刻发现的地方——放过它们，界面会静默显示错位的名次。
///
/// **站点在两种渲染之间摇摆**，同一板块连续请求会随机命中（实测）：
///
/// - **旧渲染**：榜单数据在 HTML 里——`loaderData[rank_…/page].content` 内联，或挂在
///   `mergeLoaderData` / `router-data-fn` 脚本上。本函数能解。
/// - **新渲染**：HTML 里**完全没有榜单数据**（`rankList` 零次出现），页面交给 React
///   客户端另行请求。此时无论 Go 还是这里都解不出来，都会抛「格式或分页已变化」。
///
/// 所以调用方应当**重试几次**，而不是把一次失败当成站点改版。实测失败率约一半。
RankingPage parseRanking(String body, RankingBoard board, int page) {
  final failure = HongguoRequestException('红果榜单格式或分页已变化，请稍后重试');
  final loaderKey = 'rank_${board.path}/page';
  final loader = nestedMap(
    parseRouterData(body),
    ['loaderData', loaderKey],
  );
  if (mapString(loader, const ['rankKey']) != board.upstreamKey ||
      mapString(loader, const ['pageNum']) != '$page') {
    throw failure;
  }

  // `content` 可能内联、在 mergeLoaderData 脚本里、或挂在 router-data-fn 上。
  _RankingContent? content;
  final inline = nestedMap(loader?['content'], const <String>[]);
  if (inline != null && inline.isNotEmpty) {
    content = _parseRankingContent(inline);
  } else {
    final merged = _parseMergeLoader(body, loaderKey);
    content = merged.found
        ? merged.content
        : _parseRouterDataFn(body, loaderKey);
  }

  if (content == null ||
      !content.success ||
      content.page != page ||
      content.totalPages < page ||
      content.totalPages > 500) {
    throw failure;
  }

  final items = <RankingItem>[];
  final seen = <String>{};
  var previous = (page - 1) * 20;
  for (final row in content.rows) {
    final id = firstNonEmpty([row.seriesId, row.id]);
    if (!numericIdPattern.hasMatch(id) ||
        (row.id.isNotEmpty && row.seriesId.isNotEmpty && row.id != row.seriesId) ||
        row.title.trim().isEmpty ||
        row.rank <= previous ||
        row.rank > page * 20 ||
        !seen.add(id)) {
      throw failure;
    }
    previous = row.rank;

    final cover = coverAddress([coverPathFromAny(row.cover)]);
    final totalEpisode =
        row.episodeVids.isNotEmpty ? '${row.episodeVids.length}' : '';
    final score = row.score.startsWith('评分')
        ? row.score.substring('评分'.length)
        : row.score;

    items.add(
      RankingItem(
        rank: row.rank,
        metric: row.heat,
        drama: Drama(
          id: dramaId(id),
          source: hongguoSource,
          sourceId: id,
          title: row.title,
          name: row.title,
          desc: row.description,
          intro: row.description,
          cover: cover,
          coverUrl: cover,
          categoryName: row.tags.isNotEmpty ? row.tags.first : '',
          channelName: '红果',
          totalEpisode: totalEpisode,
          tags: row.tags,
          score: score,
          heat: row.heat,
        ),
      ),
    );
  }
  if (items.isEmpty && page < content.totalPages) {
    throw failure;
  }

  return RankingPage(
    boardId: board.id,
    page: page,
    items: items,
    totalPages: content.totalPages,
    hasMore: page < content.totalPages,
    updatedText: mapString(loader, const ['updatedText']),
  );
}

/// 榜单相关的客户端方法。对照 Go `hongguo/rankings.go` 的 `Client.FetchRanking`。
extension HongguoRankingApi on HongguoClient {
  /// 取榜单一页（约 20 条，免签名）。对照 Go 的 `Client.FetchRanking`。
  Future<RankingPage> fetchRanking(RankingBoard board, int page) async {
    final base = trimTrailingSlash(webBase);
    final body = await fetchText(
      '$base/rank/${board.path}?page=$page',
      referer: '$base/',
    );
    return parseRanking(body, board, page);
  }
}

class _RankingContent {
  const _RankingContent({
    required this.success,
    required this.rows,
    required this.page,
    required this.totalPages,
  });

  final bool success;
  final List<_RankingRow> rows;
  final int page;
  final int totalPages;
}

class _RankingRow {
  const _RankingRow({
    required this.id,
    required this.seriesId,
    required this.rank,
    required this.title,
    required this.heat,
    required this.score,
    required this.description,
    required this.tags,
    required this.episodeVids,
    required this.cover,
  });

  final String id;
  final String seriesId;
  final int rank;
  final String title;
  final String heat;
  final String score;
  final String description;
  final List<String> tags;
  final List<String> episodeVids;
  final Object? cover;
}

/// 把一份 `content` 对象映射成结构化内容；形状不对返回 null。
///
/// 比 Go 松的地方：那边 `json.Unmarshal` 会因为任何一个字段类型不符而整份失败，
/// 这里只对 `rank`（必须是数字）和 `rankList`（必须是数组）严格，其余走宽松取值。
/// 站点把某个字段改成别的类型时，这里会继续工作而 Go 会报错——属于可接受的偏差。
_RankingContent? _parseRankingContent(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;

  final rawRows = raw['rankList'];
  if (rawRows is! List) return null;

  final rows = <_RankingRow>[];
  for (final row in rawRows) {
    if (row is! Map<String, dynamic>) return null;
    final rank = row['rank'];
    if (rank is! num) return null;
    rows.add(
      _RankingRow(
        id: mapString(row, const ['id']),
        seriesId: mapString(row, const ['seriesId']),
        rank: rank.toInt(),
        title: mapString(row, const ['title']),
        heat: mapString(row, const ['heatText']),
        score: mapString(row, const ['scoreText']),
        description: mapString(row, const ['description']),
        tags: mapStringSlice(row, const ['tags']),
        episodeVids: mapStringSlice(row, const ['episodeVids']),
        cover: row['cover'],
      ),
    );
  }

  final pagination =
      nestedMap(raw, const ['pagination']) ?? const <String, dynamic>{};
  return _RankingContent(
    success: raw['isSuccess'] == true,
    rows: rows,
    page: int.tryParse(mapString(pagination, const ['pageNum'])) ?? 0,
    totalPages: int.tryParse(mapString(pagination, const ['totalPages'])) ?? 0,
  );
}

/// 从 `mergeLoaderData` 脚本里取 `content`。
///
/// 返回 `found` 表示「找到了这个 loader 的条目」——找到但内容坏了也要如实说，
/// 否则调用方会去试下一种结构，把「坏数据」误当成「另一种版式」。
({_RankingContent? content, bool found}) _parseMergeLoader(
  String body,
  String loaderKey,
) {
  for (final tag in scriptTags(body)) {
    if (extractAttr(tag, const ['data-fn-name']) != 'mergeLoaderData') continue;
    if (extractAttr(tag, const ['data-script-src']) !=
        'modern-run-window-fn') {
      continue;
    }
    final args = _jsonList(extractAttr(tag, const ['data-fn-args']));
    if (args == null || args.length != 2 || args[0] != loaderKey) continue;

    final fields = args[1];
    if (fields is! List) continue;
    for (final field in fields) {
      if (field is! Map<String, dynamic>) continue;
      if (mapString(field, const ['key']) != 'content') continue;
      if (mapString(field, const ['routerDataFnName']) != 'p') continue;

      final fnArgs = field['routerDataFnArgs'];
      if (fnArgs is! List || fnArgs.length != 1) {
        return (content: null, found: true);
      }
      final raw = fnArgs[0];
      if (raw is! String) return (content: null, found: true);
      return (content: _parseRankingContent(decodeJsonObject(raw)), found: true);
    }
  }
  return (content: null, found: false);
}

/// 从 `modern-run-router-data-fn` 的 `data-fn-args` 里取 `content`。
_RankingContent? _parseRouterDataFn(String body, String loaderKey) {
  for (final tag in scriptTags(body)) {
    if (extractAttr(tag, const ['data-fn-name']) != 'r') continue;
    if (extractAttr(tag, const ['data-script-src']) !=
        'modern-run-router-data-fn') {
      continue;
    }
    final args = _jsonList(extractAttr(tag, const ['data-fn-args']));
    if (args == null || args.length != 3) continue;
    if (args[0] != loaderKey || args[1] != 'content') continue;
    return _parseRankingContent(args[2]);
  }
  return null;
}

List<Object?>? _jsonList(String text) {
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? decoded : null;
  } on FormatException {
    return null;
  }
}
