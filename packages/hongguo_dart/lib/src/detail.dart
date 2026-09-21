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
  /// 取详情 + 分集。
  ///
  /// 目前只走 App 签名接口；网页 `/detail?series_id=` 兜底是阶段 2 的事
  /// （见 `docs/plan.md`）。
  Future<DramaDetail> fetchDetail(String seriesId) async {
    final normalized =
        seriesId.trim().replaceFirst(RegExp(r'^hg-series-v1:'), '');
    if (!numericIdPattern.hasMatch(normalized)) {
      throw HongguoRequestException('红果剧集 ID 无效');
    }
    final result = await appRequest(
      method: 'POST',
      path: '/novel/player/video_detail/v1/',
      payload: {'series_id': normalized},
    );
    return parseAppDetail(result, normalized);
  }

  /// 取网页详情的社交数据（评分）。对照 Go 的 `Client.FetchWebSocialInfo`。
  ///
  /// **取不到就当没有**，不抛：评分是锦上添花，不该因为它拖垮整个详情页。网页是
  /// 免签名的，页大小约 290 KB，但 `/detail` 在 TTL 缓存白名单里（见 `lib/data/network.dart`），
  /// 同一部剧短时间内不会重复拉。
  Future<SocialInfo> fetchWebSocialInfo(String seriesId) async {
    final normalized =
        seriesId.trim().replaceFirst(RegExp(r'^hg-series-v1:'), '');
    if (!numericIdPattern.hasMatch(normalized)) return const SocialInfo();
    final base = trimTrailingSlash(webBaseUrl);
    try {
      final body = await fetchText(
        '$base/detail?series_id=${Uri.encodeQueryComponent(normalized)}',
        referer: '$base/',
      );
      return parseWebSocialInfo(body);
    } on HongguoRequestException {
      // fetchText 的传输 / 状态码 / 拦截页失败都抛这个。评分缺席不该让详情页出错。
      return const SocialInfo();
    }
  }
}
