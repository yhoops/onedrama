import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'client.dart';
import 'ids.dart';
import 'json.dart';
import 'web.dart';

/// 搜索结果。对照 Go 的 `SearchResult`。
class SearchResult {
  const SearchResult({
    required this.dramas,
    this.total = 0,
    this.limited = false,
    this.warning = '',
  });

  final List<Drama> dramas;
  final int total;

  /// 结果被截断（服务端总数大于实际返回，或有一路挂了）。
  final bool limited;

  final String warning;
}

/// 联想词条。对照 Go 的 `Suggestion`。
class Suggestion {
  const Suggestion({required this.name, this.type = ''});

  final String name;

  /// `short_play_name` / `common_query` 等；不认识的一律留空。
  final String type;
}

/// 联想接口的原始记录。对照 Go 的 `suggestionRecord`。
class SuggestionRecord {
  const SuggestionRecord({
    required this.name,
    required this.wordType,
    this.keyword,
    this.videoData,
  });

  final String name;
  final String wordType;
  final Object? keyword;
  final Map<String, dynamic>? videoData;
}

/// 校验搜索词。对照 Go 的 `SearchKeyword`。
///
/// 80 个**字符**（不是字节）且不许含控制字符——搜索词会被拼进 URL 路径。
String normalizeSearchKeyword(String keyword) {
  final text = keyword.trim();
  final hasControl = text.runes.any(
    (rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f),
  );
  if (text.isEmpty || text.runes.length > 80 || hasControl) {
    throw HongguoRequestException('请输入 1 至 80 个字符的搜索词');
  }
  return text;
}

/// 搜索用的归一化：去空白与标点、转小写。
///
/// 对照 Go 的 `SearchText`。**已知偏差**：Go 先做 `norm.NFKC` 完整兼容分解，Dart
/// 没有内置实现，这里退一步只做「全角 → 半角」折叠——够覆盖中文标题里常见的全角
/// 标点与数字。真要严格对齐得引入 unorm_dart。
String searchText(String text) {
  final buffer = StringBuffer();
  for (final rune in _foldWidth(text).runes) {
    final ch = String.fromCharCode(rune);
    if (_isSpaceOrPunct(rune)) continue;
    buffer.write(ch.toLowerCase());
  }
  final normalized = buffer.toString();
  return normalized.isEmpty ? text.trim().toLowerCase() : normalized;
}

/// 标题与搜索词的相关度：完全相同 0、前缀 1、包含 2、其它 3。
///
/// 对照 Go 的 `TitleSearchRank`。数值越小越靠前。
int titleSearchRank(String title, String normalizedQuery) {
  final text = searchText(title);
  if (text == normalizedQuery) return 0;
  if (text.startsWith(normalizedQuery)) return 1;
  if (text.contains(normalizedQuery)) return 2;
  return 3;
}

/// 解析网页搜索结果。对照 Go 的 `ParseSearchPage`。
SearchResult parseSearchPage(String body, String keyword) {
  final page = routerLoaderMap(
    parseRouterData(body),
    const ['search_(keyword)/page', 'search_'],
  );
  final rows = page?['searchList'];
  if (page == null ||
      page['isSuccess'] != true ||
      rows is! List ||
      mapString(page, const ['query']) != keyword) {
    throw HongguoRequestException('红果搜索未返回有效结果');
  }

  final dramas = <Drama>[];
  final seen = <String>{};
  for (final row in rows) {
    final video = nestedMap(row, const ['video_data']);
    if (video == null || video.isEmpty) continue;
    final drama = dramaFromAny(row, category: '短剧');
    if (drama.id.isNotEmpty && seen.add(drama.id)) dramas.add(drama);
  }
  if (rows.isNotEmpty && dramas.isEmpty) {
    throw HongguoRequestException('红果搜索结果中没有可识别的剧集');
  }

  var total = int.tryParse(mapString(page, const ['totalCount'])) ?? 0;
  final limited = total > dramas.length;
  if (total < dramas.length) total = dramas.length;
  return SearchResult(dramas: dramas, total: total, limited: limited);
}

/// 搜索相关的客户端方法。对照 Go `hongguo/search.go`。
extension HongguoSearchApi on HongguoClient {
  /// 取联想记录（免签名）。对照 Go 的 `Client.FetchSuggestionRecords`。
  Future<List<SuggestionRecord>> fetchSuggestionRecords(
    String query,
    int count,
  ) async {
    final base = trimTrailingSlash(webBase);
    final url = Uri.parse('$base/incent_resource/suggestion')
        .replace(
          queryParameters: <String, String>{
            'app_id': appAid,
            'query': query,
            'count': '$count',
          },
        )
        .toString();
    final host = Uri.tryParse(url)?.host ?? url;

    try {
      final response = await http
          .get<String>(
            url,
            options: Options(
              headers: <String, String>{
                'User-Agent': webUserAgent,
                'Referer': '$base/',
                'Accept': 'application/json',
                'Accept-Language': 'zh-CN,zh;q=0.9',
              },
            ),
          )
          .timeout(const Duration(seconds: 5));

      final body = response.data ?? '';
      if (utf8.encode(body).length > 256 * 1024) {
        throw HongguoRequestException('红果搜索联想响应过大');
      }
      final status = response.statusCode ?? 0;
      final reason = catalogBlockReason(flattenHeaders(response.headers), body);
      if (status != 200) {
        throw HongguoRequestException(
          reason.isEmpty ? '$host HTTP $status' : '$host HTTP $status：$reason',
          rawResponse: body,
        );
      }
      if (reason.isNotEmpty) {
        throw HongguoRequestException(
          '$host HTTP $status：$reason',
          rawResponse: body,
        );
      }

      final items = decodeJsonObject(body)?['suggest_list'];
      if (items is! List) {
        throw HongguoRequestException('红果搜索联想未返回有效数据');
      }
      final out = <SuggestionRecord>[];
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        out.add(
          SuggestionRecord(
            name: mapString(item, const ['name']),
            wordType: mapString(item, const ['word_type']),
            keyword: item['keyword'],
            videoData: nestedMap(item, const ['video_data']),
          ),
        );
      }
      return out;
    } on DioException catch (error) {
      throw HongguoRequestException(
        '红果搜索联想请求失败：${error.message ?? error.type.name}',
      );
    } on TimeoutException {
      throw HongguoRequestException('红果搜索联想超时');
    }
  }

  /// 名称联想（最多 10 条）。对照 Go 的 `Client.SearchSuggestions`。
  Future<List<Suggestion>> searchSuggestions(String query) async {
    final keyword = normalizeSearchKeyword(query);
    final records = await fetchSuggestionRecords(keyword, 10);
    const knownTypes = <String>{
      'short_play_name',
      'short_play_category',
      'common_query',
      'actor_name',
      'short_play_actor',
    };

    final items = <Suggestion>[];
    final seen = <String>{};
    for (final record in records) {
      String name;
      try {
        name = normalizeSearchKeyword(record.name);
      } on HongguoRequestException {
        continue;
      }
      if (!seen.add(name.toLowerCase())) continue;
      items.add(
        Suggestion(
          name: name,
          type: knownTypes.contains(record.wordType) ? record.wordType : '',
        ),
      );
      if (items.length == 10) break;
    }
    return items;
  }

  /// 综合搜索：网页搜索 ∪ 剧名联想，按 ID 去重、标题相关度排序。
  ///
  /// 对照 Go 的 `Client.Search`。两路各失败各的都不致命——只要有一路出结果就返回，
  /// 并用 `warning` 说明另一路挂了。
  Future<SearchResult> search(String query) async {
    final keyword = normalizeSearchKeyword(query);

    // 第一路：联想里的剧名（免签名，通常比网页快）。
    List<Drama> names = const <Drama>[];
    Object? namesError;
    try {
      final records = await fetchSuggestionRecords(keyword, 50);
      final collected = <Drama>[];
      for (final record in records) {
        if (record.wordType != 'short_play_name') continue;
        final videoData = record.videoData;
        if (!numericIdPattern.hasMatch(
          mapString(videoData, const ['series_id_str', 'series_id']),
        )) {
          continue;
        }
        final drama = dramaFromAny(<String, dynamic>{
          'video_data': videoData,
          'name': record.name,
          'keyword': record.keyword,
        }, category: '短剧');
        // 标题就是 ID 的，说明没取到真标题，不要。
        if (drama.id.isNotEmpty && drama.displayTitle != drama.sourceId) {
          collected.add(drama);
        }
      }
      names = collected;
    } catch (error) {
      namesError = error;
    }

    // 第二路：网页搜索。
    SearchResult? page;
    Object? pageError;
    try {
      final base = trimTrailingSlash(webBase);
      final body = await fetchText(
        '$base/search/${Uri.encodeComponent(keyword)}',
        referer: '$base/',
      ).timeout(const Duration(seconds: 12));
      page = parseSearchPage(body, keyword);
    } catch (error) {
      pageError = error;
    }

    final pageDramas = page?.dramas ?? const <Drama>[];
    if ((pageError != null && namesError != null) ||
        (pageDramas.isEmpty && names.isEmpty && (pageError != null || namesError != null))) {
      throw HongguoRequestException(
        '红果搜索失败：网页 $pageError；联想 $namesError',
      );
    }

    // 按 ID 去重，网页结果为主、联想补缺。
    final merged = <Drama>[];
    final positions = <String, int>{};
    for (final batch in [pageDramas, names]) {
      for (final drama in batch) {
        final index = positions[drama.id];
        if (index != null) {
          merged[index] = mergeDrama(merged[index], drama);
        } else {
          positions[drama.id] = merged.length;
          merged.add(drama);
        }
      }
    }

    final normalized = searchText(keyword);
    final ranked = <(int, int, Drama)>[
      for (var i = 0; i < merged.length; i++)
        (titleSearchRank(merged[i].displayTitle, normalized), i, merged[i]),
    ]..sort((left, right) {
        final byRank = left.$1.compareTo(right.$1);
        return byRank != 0 ? byRank : left.$2.compareTo(right.$2);
      });

    var warning = '';
    if (pageError != null) {
      warning = '红果综合搜索暂不可用，已保留名称匹配结果，可重试';
    } else if (namesError != null) {
      warning = '红果名称检索暂不可用，结果可能缺少部分剧集，可重试';
    }

    final dramas = [for (final entry in ranked) entry.$3];
    var total = page?.total ?? 0;
    if (total < dramas.length) total = dramas.length;
    return SearchResult(
      dramas: dramas,
      total: total,
      limited: (page?.limited ?? false) || pageError != null || namesError != null,
      warning: warning,
    );
  }
}

/// 全角 → 半角折叠，凑合替代 NFKC 里最常用的一部分。
String _foldWidth(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 是不是空白或标点。近似 Go 的 `unicode.IsSpace || unicode.IsPunct`。
///
/// 只用于排序相关度，不需要严格；全角标点已在折叠阶段转成 ASCII 了。
bool _isSpaceOrPunct(int rune) {
  if (rune == 0x20 || (rune >= 0x09 && rune <= 0x0D)) return true;
  if (rune == 0xA0 || rune == 0x3000 || rune == 0x200B) return true;
  if (rune >= 0x21 && rune <= 0x2F) return true;
  if (rune >= 0x3A && rune <= 0x40) return true;
  if (rune >= 0x5B && rune <= 0x60) return true;
  if (rune >= 0x7B && rune <= 0x7E) return true;
  if (rune >= 0x2000 && rune <= 0x206F) return true;
  if (rune >= 0x3001 && rune <= 0x303F) return true;
  if (rune >= 0xFF01 && rune <= 0xFF0F) return true;
  if (rune >= 0xFF1A && rune <= 0xFF20) return true;
  if (rune >= 0xFF3B && rune <= 0xFF40) return true;
  if (rune >= 0xFF5B && rune <= 0xFF65) return true;
  return false;
}
