import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// 联网冒烟：真的打红果接口。
///
/// 默认整组跳过——离线跑 `dart test` 不该发请求：
///
///   LIVE=1 dart test test/live_test.dart
///
/// 这组是「签名是否被服务端接受」的唯一硬证据。契约测试（protocol_test.dart）
/// 只能保证 Dart 和 Go 一致；两边一起错，只有这里能发现。
void main() {
  final skip = Platform.environment['LIVE'] == '1' ? null : '设置 LIVE=1 才打真接口';

  test('联想接口（免签名）能挖到真实 series_id', () async {
    final ids = await discoverSeriesIds(HongguoClient());
    expect(ids, isNotEmpty);
    for (final id in ids) {
      expect(numericIdPattern.hasMatch(id), isTrue, reason: id);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('签名被接受：详情 + 取流拿到 URL 与 16 字节 CENC 密钥', () async {
    final client = HongguoClient();
    final ids = await discoverSeriesIds(client);
    expect(ids, isNotEmpty, reason: '挖不到 ID 就没法验证签名');

    final detail = await client.fetchDetail(ids.first);
    expect(detail.drama.title, isNotEmpty);
    expect(detail.episodes, isNotEmpty);
    expect(detail.drama.sourceId, ids.first);
    // 分集从 1 开始且连续；parseAppDetail 自己会校验，这里再钉一次。
    for (var index = 0; index < detail.episodes.length; index++) {
      expect(detail.episodes[index].number, index + 1);
    }

    final episode = detail.episodes.first;
    expect(episode.mediaUrl, mediaPlaceholder(episode.videoId));

    final media = await client.resolveAppMedia(episode.videoId);
    expect(media.url, startsWith('http'));
    expect(media.quality, greaterThan(0));
    // App 源的正片基本都加密；拿到明文也算过，但不能两者都没有。
    expect(media.cencKey == null || media.cencKey!.length == 16, isTrue);
    expect(media.variants, isNotEmpty);
    // 备选地址（`backup_url`，实测落在另一个 CDN 主机上）必须被收进来——丢了的话
    // 主地址一挂就整集播不了，而它是免费拿到的冗余。
    expect(
      <Media>[media, ...media.variants].any((m) => m.backupUrls.isNotEmpty),
      isTrue,
      reason: '一档备选地址都没收到，backup_url 的解析可能已失效',
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('网页详情能独立解析出完整分集（App 详情失效后唯一可用的源）', () async {
    final client = HongguoClient();
    final ids = await discoverSeriesIds(client);
    expect(ids, isNotEmpty, reason: '挖不到 ID 就没法验证');

    final body = await client.fetchText(
      client.webDetailUrl(ids.first),
      referer: client.webDetailReferer,
    );
    final detail = parseWebDetail(body, ids.first);
    expect(detail.drama.title, isNotEmpty);
    expect(detail.drama.sourceId, ids.first);
    expect(detail.episodes, isNotEmpty);
    // 网页只给一串 vid、不给集号，集号是下标 + 1 —— 这里钉死它连续。
    for (var index = 0; index < detail.episodes.length; index++) {
      expect(detail.episodes[index].number, index + 1);
      expect(numericIdPattern.hasMatch(detail.episodes[index].videoId), isTrue);
    }
    // 注意：网页**没有播放量**（`views` 为空是正常的，不是解析坏了）。要显示播放量的
    // 调用方得用 `mergeDrama` 从分类快照并回来，见 `lib/ui/detail_page.dart`。
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  // ---- 阶段 2：发现层 ----

  test('分类分页：一页有结果，游标推进且第二页不重', () async {
    final client = HongguoClient();
    final genre = appGenres.first;
    final page = await client.fetchCatalogPage(
      genreKey: genre.key,
      scene: genre.scene,
      category: genre.name,
      cursor: const CatalogCursor(),
    );
    expect(page.dramas, isNotEmpty);
    expect(page.cursor.initialized, isTrue);
    expect(page.cursor.offset, greaterThan(0));
    for (final drama in page.dramas) {
      expect(numericIdPattern.hasMatch(drama.sourceId), isTrue, reason: drama.id);
      expect(drama.title, isNotEmpty, reason: drama.id);
    }

    // 翻第二页。`fetchCatalogPage` 内部有 pageSignature 守卫：服务端把同一页重发
    // 一次，它会抛错而不是悄悄返回重复内容——所以这里能拿到结果本身就说明推进了。
    final second = await client.fetchCatalogPage(
      genreKey: genre.key,
      scene: genre.scene,
      category: genre.name,
      cursor: page.cursor,
    );
    expect(second.dramas, isNotEmpty);
    expect(second.cursor.offset, greaterThan(page.cursor.offset));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('榜单：能解析出 20 条一页且名次严格递增', () async {
    final client = HongguoClient();
    // 站点在两种渲染之间摇摆（见 `parseRanking` 的注释）：旧渲染把榜单塞在 HTML 里，
    // 新渲染交给 React 另行请求，此时 Go 与 Dart 都解不出来。所以这里重试——
    // 拿到旧渲染时解析必须完全正确，六轮一次都没拿到才算失败。
    var parsed = 0;
    Object? lastError;
    for (var attempt = 0; attempt < 6 && parsed == 0; attempt++) {
      for (final board in rankingBoards) {
        try {
          final page = await client.fetchRanking(board, 1);
          expect(page.items, isNotEmpty, reason: board.id);
          expect(page.boardId, board.id);
          var previous = 0;
          for (final item in page.items) {
            expect(item.rank, greaterThan(previous), reason: board.id);
            expect(item.rank, lessThanOrEqualTo(20), reason: board.id);
            expect(item.drama.title, isNotEmpty, reason: board.id);
            expect(numericIdPattern.hasMatch(item.drama.sourceId), isTrue);
            previous = item.rank;
          }
          parsed++;
        } catch (error) {
          lastError = error;
        }
      }
    }
    expect(parsed, greaterThan(0), reason: '六轮都没拿到可解析的渲染：$lastError');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('搜索：网页 ∪ 联想有结果，联想单独也能用', () async {
    final client = HongguoClient();
    final result = await client.search('总裁');
    expect(result.dramas, isNotEmpty);
    for (final drama in result.dramas) {
      expect(numericIdPattern.hasMatch(drama.sourceId), isTrue, reason: drama.id);
    }
    // 相关度排序：完全相同/前缀/包含的应当排在其它前面。
    final normalized = searchText('总裁');
    final ranks = [
      for (final drama in result.dramas)
        titleSearchRank(drama.displayTitle, normalized),
    ];
    expect(ranks, equals(<int>[...ranks]..sort()), reason: '排序不是按相关度递增的');

    final suggestions = await client.searchSuggestions('总裁');
    expect(suggestions, isNotEmpty);
    expect(suggestions.length, lessThanOrEqualTo(10));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('网页分类（免签名）有结果，且 ?page=N 真的翻页', () async {
    final client = HongguoClient();
    final category = webCategories.first;
    final first = await client.fetchWebCategoryPage(
      route: category.path,
      category: category.name,
    );
    expect(first.dramas, isNotEmpty);
    expect(first.page, 1);
    expect(first.totalPages, greaterThan(1));

    // **这一条是整标签降级的前提**：App 分类挂掉后整个标签都走 ?page=N，如果服务端
    // 忽略页码，降级就会原地打转、永远拉同一页。实测相邻页 0 重叠。
    final second = await client.fetchWebCategoryPage(
      route: category.path,
      category: category.name,
      page: 2,
    );
    expect(second.page, 2);
    expect(second.dramas, isNotEmpty);
    final firstIds = first.dramas.map((drama) => drama.id).toSet();
    final overlap = second.dramas.where((drama) => firstIds.contains(drama.id));
    expect(overlap, isEmpty, reason: '第 2 页与第 1 页有重叠，页码可能没生效');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('三级取流：resolveMedia 拿到可播地址与 Referer', () async {
    final client = HongguoClient();
    final ids = await discoverSeriesIds(client);
    expect(ids, isNotEmpty);
    final detail = await client.fetchDetail(ids.first);
    final episode = detail.episodes.first;
    final media = await client.resolveMedia(ids.first, episode.videoId);
    expect(media.url, startsWith('http'));
    expect(media.referer, isNotEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}

/// 用免签名的联想接口挖真实 series_id。
///
/// 对应 Go 里 `SearchSuggestions` 用的那个端点，这里只取 ID、不做搜索解析
/// （完整搜索是阶段 2 的事）。
Future<List<String>> discoverSeriesIds(
  HongguoClient client, {
  String keyword = '总裁',
}) async {
  final url = '$webBaseUrl/incent_resource/suggestion'
      '?app_id=$appAid&query=${Uri.encodeQueryComponent(keyword)}&count=10';
  final response = await client.http.get<String>(
    url,
    options: Options(
      headers: {
        'User-Agent': webUserAgent,
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': webBaseUrl,
      },
    ),
  );
  final decoded = decodeJsonObject(response.data ?? '');
  if (decoded == null) return const [];

  final found = <String>[];
  for (final item in anyList(decoded['suggest_list'])) {
    final map = item is Map<String, dynamic> ? item : const <String, dynamic>{};
    final video = nestedMap(map, const ['video_data']);
    final id = dramaFromAny(video ?? map).sourceId;
    if (id.isNotEmpty && !found.contains(id)) found.add(id);
  }
  return found;
}
