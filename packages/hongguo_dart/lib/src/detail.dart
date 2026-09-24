import 'client.dart';
import 'ids.dart';
import 'json.dart';
import 'web.dart';

/// 从 App 详情响应里解析出剧与分集。对照 Go 的 `ParseAppDetail`。
///
/// 校验比 Go 更硬的地方：那边返回部分结果 + error，调用方会丢掉；这里直接抛。
DramaDetail parseAppDetail(Map<String, dynamic> result, String seriesId) {
  final detail = nestedMap(result, const ['data', 'video_data']);
  final returnedId = mapString(detail, const ['series_id_str', 'series_id']);
  if (returnedId != seriesId) {
    throw HongguoRequestException('红果 App 未返回所请求的剧集');
  }

  final drama = dramaFromAny(detail, category: '短剧');
  final seenVideos = <String>{};
  final seenNumbers = <int>{};
  final episodes = <Episode>[];

  for (final row in anyList(detail?['video_list'])) {
    if (row is! Map<String, dynamic>) continue;
    final videoId = mapString(row, const ['vid']);
    final number = int.tryParse(mapString(row, const ['vid_index']));
    if (number == null || number < 1 || !numericIdPattern.hasMatch(videoId)) {
      throw HongguoRequestException('红果 App 分集编号或视频 ID 无效');
    }
    final owner = mapString(row, const ['series_id']);
    if (owner.isNotEmpty && owner != seriesId) {
      throw HongguoRequestException('红果 App 返回了其他剧集的分集');
    }
    if (!seenVideos.add(videoId) || !seenNumbers.add(number)) {
      throw HongguoRequestException('红果 App 返回了重复分集');
    }
    episodes.add(
      Episode(
        id: episodeId(seriesId, videoId),
        number: number,
        title: '第$number集',
        videoId: videoId,
        mediaUrl: mediaPlaceholder(videoId),
      ),
    );
  }

  episodes.sort((left, right) => left.number.compareTo(right.number));

  final total = int.tryParse(mapString(detail, const ['episode_cnt'])) ?? 0;
  if (episodes.isEmpty || total > episodes.length) {
    throw HongguoRequestException('红果 App 未返回完整分集，已尝试其他详情入口');
  }
  for (var index = 0; index < episodes.length; index++) {
    if (episodes[index].number != index + 1) {
      throw HongguoRequestException('红果 App 分集列表不连续');
    }
  }
  return DramaDetail(drama: drama, episodes: episodes);
}

/// 从网页详情 HTML 里解析出剧与分集。对照 Go 的 `ParseWebDetail`。
///
/// 这是 [HongguoDetailApi.fetchDetail] 的**第二条腿**，也是现在唯一还能用的那条：
/// 上游 `/novel/player/video_detail/v1/` 已失效（HTTP 200 但响应体为空），而网页
/// `_ROUTER_DATA` 里的 `seriesDetail` 仍然完整——标题、简介、标签、分类、集数与
/// `vid_list` 都在，且 `vid_list` 的长度与分类接口给的集数逐部一致（实测 6 部）。
///
/// 网页**没有播放量**（也没有热度）。调用方要播放量的话，用 [mergeDrama] 把分类快照
/// 并回来，不要在这里编一个。
///
/// 与 Go 的差别：网页给了 `series_id` 就核对，对不上直接抛。Go 不核对，宁可报
/// 「返回了其他剧集」也别把别的剧的分集挂到这部剧上。
DramaDetail parseWebDetail(String body, String seriesId) {
  final page = routerLoaderMap(
    parseRouterData(body),
    const ['detail_page', 'detail_'],
  );
  final detail = nestedMap(page, const ['seriesDetail']);
  if (detail == null || detail.isEmpty) {
    throw HongguoRequestException('红果网页详情为空，页面结构可能已变化');
  }
  final returnedId = mapString(detail, const ['series_id', 'series_id_str']);
  if (returnedId.isNotEmpty && returnedId != seriesId) {
    throw HongguoRequestException('红果网页详情返回了其他剧集');
  }

  final episodes = <Episode>[];
  final vids = anyList(detail['vid_list']);
  for (var index = 0; index < vids.length; index++) {
    final raw = vids[index];
    final videoId = raw == null ? '' : '$raw'.trim();
    // 网页只给一串 vid、不给集号，所以集号 = **下标 + 1**。任何一项不是合法 vid
    // 就整页判不可用：悄悄跳过会让后面的集号整体前移，症状是「选集里第 7 集其实是
    // 第 8 集」，比直接报错难查得多。
    if (!numericIdPattern.hasMatch(videoId)) {
      throw HongguoRequestException('红果网页详情含无效视频 ID');
    }
    final number = index + 1;
    episodes.add(
      Episode(
        id: episodeId(seriesId, videoId),
        number: number,
        title: '第$number集',
        videoId: videoId,
        mediaUrl: mediaPlaceholder(videoId),
      ),
    );
  }
  if (episodes.isEmpty) {
    throw HongguoRequestException('红果网页详情没有返回剧集 ID');
  }

  var drama = dramaFromAny(detail, category: '短剧');
  if (drama.title.isEmpty || drama.sourceId.isEmpty) {
    drama = mergeDrama(
      drama,
      Drama(
        id: dramaId(seriesId),
        source: hongguoSource,
        sourceId: seriesId,
        title: firstNonEmpty([
          mapString(detail, const ['series_name', 'series_title', 'name']),
          seriesId,
        ]),
      ),
    );
  }
  return DramaDetail(drama: drama, episodes: episodes);
}

/// 网页详情里的社交数据。对照 Go 的 `SocialInfo`。
///
/// **App 详情接口没有这些字段。** App 的 `/novel/player/video_detail/v1/` 返回 39 个字段，
/// 键名含 `score`/`rating`/`heat`/`hot` 的只有一个 `hot_score`——评分只能从网页拿。
class SocialInfo {
  const SocialInfo({this.rating = 0, this.ratingCount = ''});

  /// 评分，如 9.2。**0 表示这部剧本就没评分**（实测 5 部里 2 部没有），不是解析失败。
  final double rating;

  /// 评分人数，如 `33371`（上游给的是字符串）。
  final String ratingCount;

  bool get hasRating => rating > 0;
}

/// 从网页详情 HTML 里取社交数据——目前只有评分。
///
/// 注意 `seriesSocialInfo` 与 `seriesDetail` 是**同级**字段，不在它里面；写进
/// `seriesDetail` 里查会永远查不到。
///
/// 对照 Go 的 `ParseWebSocialInfo`。
SocialInfo parseWebSocialInfo(String body) {
  final page = routerLoaderMap(
    parseRouterData(body),
    const ['detail_page', 'detail_'],
  );
  final social = nestedMap(page, const ['seriesSocialInfo']);
  if (social == null) return const SocialInfo();

  final rating = (social['rating'] as num?)?.toDouble() ?? 0;
  return SocialInfo(
    rating: rating > 0 ? rating : 0,
    ratingCount: mapString(social, const ['rating_count']),
  );
}

/// 详情相关的客户端方法。对照 Go `hongguo/detail.go` 的 `Client.FetchDetail`。
extension HongguoDetailApi on HongguoClient {
  /// 网页详情页的 URL。**详情与评分是同一个页面**——`seriesDetail` 与
  /// `seriesSocialInfo` 是同级字段，不在它里面。
  ///
  /// 所以取详情与取评分打的是同一个地址；`/detail` 在 TTL 缓存白名单里
  /// （`lib/data/network.dart`），第二次会直接命中，不会重复下这约 290 KB。
  ///
  /// 用 `webBase` 而不是常量——那边是可被覆盖的站点根（同 [fetchWebCategoryPage]）。
  /// 之前这里读的是常量，于是覆盖了 `webBase` 的调用方会发现详情走了覆盖后的主机、
  /// 评分却还打在默认主机上。
  String webDetailUrl(String seriesId) =>
      '${trimTrailingSlash(webBase)}/detail'
      '?series_id=${Uri.encodeQueryComponent(seriesId)}';

  /// 网页详情页要带的 Referer（站点根）。
  String get webDetailReferer => '${trimTrailingSlash(webBase)}/';

  /// 取详情 + 分集。
  ///
  /// **两条腿：App 签名接口 → 网页详情。** 顺序与 Go 的 `FetchDetail` 一致。
  ///
  /// 为什么必须有第二条：上游 `/novel/player/video_detail/v1/` 已经失效——HTTP 200
  /// 但响应体是空的（实测换 host、GET/POST、加 `book_id` 全是空体；`/video_detail/`
  /// 则返回 404，说明路径还在、只是不再吐数据）。只留 App 那条腿的话，点开任何一部剧
  /// 都会报「红果 App 接口未返回有效数据」。网页那条腿的数据是完整的（见
  /// [parseWebDetail]），所以它不是「降级方案」，是眼下唯一可用的源；上游哪天把 App
  /// 详情放回来，这里会自动用回它。
  ///
  /// 网页里**没有播放量**。要显示播放量的调用方，用 [mergeDrama] 把分类快照并回来。
  Future<DramaDetail> fetchDetail(String seriesId) async {
    final normalized =
        seriesId.trim().replaceFirst(RegExp(r'^hg-series-v1:'), '');
    if (!numericIdPattern.hasMatch(normalized)) {
      throw HongguoRequestException('红果剧集 ID 无效');
    }

    Object? appError;
    try {
      final result = await appRequest(
        method: 'POST',
        path: '/novel/player/video_detail/v1/',
        payload: {'series_id': normalized},
      );
      return parseAppDetail(result, normalized);
    } catch (error) {
      // 空体、格式异常、业务码非 0、以及 HTTP 4xx 都落这里——每一种都该试网页。
      appError = error;
    }

    try {
      final body = await fetchText(
        webDetailUrl(normalized),
        referer: webDetailReferer,
      );
      return parseWebDetail(body, normalized);
    } catch (webError) {
      // 两条腿的原因都带上——只报后一条的话，前一条为什么失败就永远查不到了。
      throw HongguoRequestException(
        '红果 App 详情失败：$appError；网页详情失败：$webError',
      );
    }
  }

  /// 取网页详情的社交数据（评分）。对照 Go 的 `Client.FetchWebSocialInfo`。
  ///
  /// **取不到就当没有**，不抛：评分是锦上添花，不该因为它拖垮整个详情页。网页是
  /// 免签名的，页大小约 290 KB，但 `/detail` 在 TTL 缓存白名单里（见
  /// `lib/data/network.dart`），而 [fetchDetail] 打的是**同一个地址**——所以
  /// 详情那条腿落到网页之后，这次调用基本都是一次缓存命中。
  Future<SocialInfo> fetchWebSocialInfo(String seriesId) async {
    final normalized =
        seriesId.trim().replaceFirst(RegExp(r'^hg-series-v1:'), '');
    if (!numericIdPattern.hasMatch(normalized)) return const SocialInfo();
    try {
      final body = await fetchText(
        webDetailUrl(normalized),
        referer: webDetailReferer,
      );
      return parseWebSocialInfo(body);
    } on HongguoRequestException {
      // fetchText 的传输 / 状态码 / 拦截页失败都抛这个。评分缺席不该让详情页出错。
      return const SocialInfo();
    }
  }
}
