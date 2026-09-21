import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'client.dart';
import 'ids.dart';
import 'json.dart';
import 'web.dart';

/// App 分类：key / scene / 显示名。对照 Go 的 `AppGenres`。
class AppGenre {
  const AppGenre({required this.key, required this.scene, required this.name});

  final String key;
  final String scene;
  final String name;
}

const List<AppGenre> appGenres = <AppGenre>[
  AppGenre(key: 'short_play', scene: 'default', name: '真人剧'),
  AppGenre(key: 'comic_series', scene: 'comic_series', name: '漫剧'),
  AppGenre(key: 'ai_series', scene: 'ai_series', name: 'AI剧'),
];

/// 网页分类：path / 显示名。对照 Go 的 `WebCategories`。
class WebCategory {
  const WebCategory({required this.path, required this.name});

  final String path;
  final String name;
}

const List<WebCategory> webCategories = <WebCategory>[
  WebCategory(path: 'real-drama', name: '真人剧'),
  WebCategory(path: 'comic-drama', name: '漫剧'),
  WebCategory(path: 'ai-drama', name: 'AI剧'),
  WebCategory(path: 'comic', name: '动漫'),
];

/// App 分类的分页游标。对照 Go 的 `CatalogCursor`。
///
/// 分页走的是 `offset` + `session_id`：session 超过 30 分钟作废，`has_more` 是唯一
/// 的终止信号，`pageSignature` 用来抓「服务端悄悄重发同一页」——没有它，翻页会
/// 悄悄陷入死循环。
class CatalogCursor {
  const CatalogCursor({
    this.offset = 0,
    this.sessionId = '',
    this.lastId = '',
    this.pageSignature = '',
    this.initialized = false,
    this.exhausted = false,
    this.updatedAt,
  });

  final int offset;
  final String sessionId;
  final String lastId;
  final String pageSignature;
  final bool initialized;
  final bool exhausted;
  final DateTime? updatedAt;

  /// session 超过这个时长就作废，必须重新起一页。
  static const Duration sessionLifetime = Duration(minutes: 30);

  CatalogCursor copyWith({
    int? offset,
    String? sessionId,
    String? lastId,
    String? pageSignature,
    bool? initialized,
    bool? exhausted,
    DateTime? updatedAt,
  }) =>
      CatalogCursor(
        offset: offset ?? this.offset,
        sessionId: sessionId ?? this.sessionId,
        lastId: lastId ?? this.lastId,
        pageSignature: pageSignature ?? this.pageSignature,
        initialized: initialized ?? this.initialized,
        exhausted: exhausted ?? this.exhausted,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'offset': offset,
        'sessionId': sessionId,
        'lastId': lastId,
        'pageSignature': pageSignature,
        'initialized': initialized,
        'exhausted': exhausted,
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory CatalogCursor.fromJson(Map<String, dynamic> json) => CatalogCursor(
        offset: (json['offset'] as num?)?.toInt() ?? 0,
        sessionId: json['sessionId'] as String? ?? '',
        lastId: json['lastId'] as String? ?? '',
        pageSignature: json['pageSignature'] as String? ?? '',
        initialized: json['initialized'] as bool? ?? false,
        exhausted: json['exhausted'] as bool? ?? false,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );
}

/// 分类一页：剧集 + 推进后的游标。
class CatalogPage {
  const CatalogPage({required this.dramas, required this.cursor});

  final List<Drama> dramas;
  final CatalogCursor cursor;
}

/// 推荐分页的请求参数。对照 Go 的 `RecommendationQuery`。
class RecommendationQuery {
  const RecommendationQuery({
    required this.genre,
    this.offset = 0,
    this.sessionId = '',
    this.seen = const <String>[],
  });

  final String genre;
  final int offset;
  final String sessionId;

  /// 已经看过的剧 ID，用来让服务端去重。
  final List<String> seen;
}

/// 推荐一页。对照 Go 的 `RecommendationPage`。
class RecommendationPage {
  const RecommendationPage({
    required this.dramas,
    required this.nextOffset,
    required this.sessionId,
    required this.hasMore,
  });

  final List<Drama> dramas;
  final int nextOffset;
  final String sessionId;
  final bool hasMore;
}

/// 解析 App 分类一页。对照 Go 的 `ParseCatalogPage`。
///
/// 与 Go 的差别：那边出错时把「没推进的游标」连同部分结果一起返回，这里直接抛——
/// 调用方拿着自己那份旧游标重试即可，语义一样但少一个易错的状态。
CatalogPage parseCatalogPage(
  Map<String, dynamic> result,
  CatalogCursor cursor,
  String category,
) {
  final data = nestedMap(result, const ['data']);
  final rawRows = data?['video_data'];
  if (rawRows is! List) {
    throw HongguoRequestException('App 分类数据格式异常');
  }

  final dramas = <Drama>[];
  final ids = <String>[];
  final seen = <String>{};
  for (final row in rawRows) {
    final drama = dramaFromAny(row, category: category);
    if (drama.id.isEmpty) continue;
    dramas.add(drama);
    if (seen.add(drama.id)) ids.add(drama.id);
  }
  if (rawRows.isNotEmpty && dramas.isEmpty) {
    throw HongguoRequestException('App 分类未返回可识别的剧集');
  }

  final parsedNext = int.tryParse(mapString(data, const ['next_offset']));
  final hasMore = data?['has_more'];
  if (hasMore is! bool || (hasMore && parsedNext == null)) {
    throw HongguoRequestException('App 分页标记无效，已保留上次位置');
  }
  final next = parsedNext ?? (cursor.offset + rawRows.length);

  var lastId = '';
  var signature = '';
  if (dramas.isNotEmpty) {
    lastId = dramas.last.id;
    signature = _sha256Hex((<String>[...ids]..sort()).join('\n'));
  }
  if (hasMore &&
      (dramas.isEmpty ||
          next <= cursor.offset ||
          next > 1000000 ||
          signature == cursor.pageSignature)) {
    throw HongguoRequestException('App 分页未前进，已保留上次位置');
  }

  return CatalogPage(
    dramas: dramas,
    cursor: CatalogCursor(
      offset: next,
      sessionId: mapString(data, const ['session_id']),
      lastId: lastId,
      pageSignature: signature,
      initialized: true,
      exhausted: !hasMore,
      updatedAt: DateTime.now(),
    ),
  );
}

String _sha256Hex(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();

bool _invalidSessionId(String value) =>
    value.length > 4096 ||
    value.contains('\r') ||
    value.contains('\n') ||
    value.contains('\x00');

Map<String, Object?> _selectorPanel(String genre, {List<String> sort = const []}) =>
    <String, Object?>{
      'genre': <String>[genre],
      'sort': sort,
      'gender': <String>[],
      'category_dim_theme': <String>[],
      'category_dim_role': <String>[],
      'category_dim_epoch': <String>[],
      'online_time': <String>[],
      'creation_status': <String>[],
    };

/// 分类与推荐相关的客户端方法。对照 Go `hongguo/catalog.go`。
extension HongguoCatalogApi on HongguoClient {
  /// App 分类一页（`limit` 固定 18）。对照 Go 的 `Client.FetchCatalogPage`。
  ///
  /// **比 Go 多一道校验**：那边不认 `genreKey` 就直接发出去，拼错只会静默返回空页，
  /// 很难查。这里先对着 [appGenres] 验一遍。
  Future<CatalogPage> fetchCatalogPage({
    required String genreKey,
    required String scene,
    required String category,
    required CatalogCursor cursor,
  }) async {
    if (!appGenres.any((genre) => genre.key == genreKey)) {
      throw HongguoRequestException('未知的分类 key：$genreKey');
    }
    final updatedAt = cursor.updatedAt;
    final sessionAlive = updatedAt != null &&
        DateTime.now().difference(updatedAt) <= CatalogCursor.sessionLifetime;

    final result = await appRequest(
      method: 'POST',
      path: '/reading/distribution/category/landpage/v/',
      payload: <String, Object?>{
        'req_scene': scene,
        'offset': cursor.offset,
        'limit': 18,
        'req_type': 'only_content',
        'need_selector_panel': false,
        'client_req_type': cursor.offset > 0 ? 2 : 3,
        'session_id': sessionAlive ? cursor.sessionId : '',
        'filter_ids': '',
        'select_items': _selectorPanel(genreKey, sort: const ['online_time']),
      },
    );
    return parseCatalogPage(result, cursor, category);
  }

  /// 网页分类一页（免签名）。对照 Go 的 `Client.FetchWebCategoryPage`。
  ///
  /// App 分类接口挂掉时的兜底。返回剧集与总页数。
  Future<({List<Drama> dramas, int totalPages})> fetchWebCategoryPage({
    required String route,
    required String category,
  }) async {
    final base = trimTrailingSlash(webBase);
    final body = await fetchText('$base/category/$route', referer: '$base/');
    final page = routerLoaderMap(
      parseRouterData(body),
      const ['category_page', r'category_$'],
    );
    if (page == null || page.isEmpty || page['isSuccess'] == false) {
      throw HongguoRequestException('红果分类数据不可用，可能是页面结构或访问权限变化');
    }

    final dramas = <Drama>[];
    for (final item in anyList(page['recommendList'])) {
      final drama = dramaFromAny(item, category: category);
      if (drama.id.isNotEmpty) dramas.add(drama);
    }
    final totalPages = int.tryParse(
          mapString(nestedMap(page, const ['pagination']), const ['totalPages']),
        ) ??
        0;
    return (dramas: dramas, totalPages: totalPages);
  }

  /// 分类推荐一页，带 `filter_ids` 去重。对照 Go 的 `Client.FetchRecommendations`。
  Future<RecommendationPage> fetchRecommendations(
    RecommendationQuery query,
  ) async {
    AppGenre? matched;
    for (final genre in appGenres) {
      if (genre.key == query.genre) matched = genre;
    }
    if (matched == null ||
        query.offset < 0 ||
        query.offset > 1000000 ||
        _invalidSessionId(query.sessionId) ||
        query.seen.length > 540) {
      throw HongguoRequestException('推荐分类或分页参数无效，请重新获取');
    }

    final seen = <String>{};
    final filterIds = <String>[];
    for (final raw in query.seen) {
      final id = raw.startsWith('$hongguoSource:')
          ? raw.substring(hongguoSource.length + 1)
          : raw;
      if (!numericIdPattern.hasMatch(id)) {
        throw HongguoRequestException('推荐分页含无效剧集 ID');
      }
      if (seen.add(id)) filterIds.add(id);
    }

    final result = await appRequest(
      method: 'POST',
      path: '/reading/distribution/category/landpage/v/',
      payload: <String, Object?>{
        'req_scene': matched.scene,
        'offset': query.offset,
        'limit': 18,
        'req_type': 'only_content',
        'need_selector_panel': false,
        'client_req_type': query.offset > 0 ? 2 : 3,
        'session_id': query.sessionId,
        'filter_ids': filterIds.join(','),
        'select_items': _selectorPanel(query.genre),
      },
    );

    final data = nestedMap(result, const ['data']);
    final rows = data?['video_data'];
    final hasMore = data?['has_more'];
    final next = int.tryParse(mapString(data, const ['next_offset']));
    if (rows is! List || hasMore is! bool || (hasMore && next == null)) {
      throw HongguoRequestException('红果推荐数据格式异常，已保留上次位置');
    }

    final dramas = <Drama>[];
    final dedupe = <String>{...seen};
    var validRows = 0;
    for (final row in rows) {
      final drama = dramaFromAny(row, category: matched.name);
      if (drama.id.isNotEmpty) validRows++;
      final id = drama.id.startsWith('$hongguoSource:')
          ? drama.id.substring(hongguoSource.length + 1)
          : drama.id;
      if (drama.id.isEmpty || !dedupe.add(id)) continue;
      dramas.add(drama);
    }
    if (rows.isNotEmpty && validRows == 0) {
      throw HongguoRequestException('红果推荐未返回可识别的剧集');
    }
    final nextOffset = next ?? query.offset;
    if (hasMore &&
        (nextOffset <= query.offset || nextOffset > 1000000 || dramas.isEmpty)) {
      throw HongguoRequestException('红果推荐分页未前进，可重试或重新获取');
    }

    final sessionId = mapString(data, const ['session_id']);
    if (_invalidSessionId(sessionId)) {
      throw HongguoRequestException('红果推荐分页标记无效');
    }
    return RecommendationPage(
      dramas: dramas,
      nextOffset: nextOffset,
      sessionId: sessionId,
      hasMore: hasMore,
    );
  }
}
