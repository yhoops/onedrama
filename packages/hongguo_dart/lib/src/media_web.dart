import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'client.dart';
import 'crypto.dart';
import 'ids.dart';
import 'json.dart';
import 'media.dart';
import 'web.dart';

/// 网页播放页单路取流。对照 Go 的 `ParseWebMedia`。
///
/// 会核对返回的 `vid` 与 `series_id`——**不能把试看集当成目标集**。这是原项目
/// 特意加的守卫，客户端重写时容易漏。
Media parseWebMedia(String body, String seriesId, String videoId) {
  final page = routerLoaderMap(
    parseRouterData(body),
    const ['player_', 'player_page'],
  );
  if (mapString(page, const ['vid']) != videoId ||
      mapString(page, const ['series_id']) != seriesId) {
    throw HongguoRequestException(
      '红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限',
    );
  }

  final info = nestedMap(page?['video_player_info'], const <String>[]);
  final mediaUrl = mapString(info, const ['main_url']);
  if (!isHttpMediaUrl(mediaUrl)) {
    throw HongguoRequestException(
      '红果该集未提供公开播放地址，可能需要登录或 App 授权；不会把试看集冒充该集',
    );
  }
  final seconds = double.tryParse(mapString(info, const ['duration'])) ?? 0;
  return Media(
    url: mediaUrl,
    referer: '$webBaseUrl/',
    duration: Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    ),
  );
}

/// 解密并解析备用播放接口的响应。对照 Go 的 `ParsePlaybackAPI`。
Media parsePlaybackApi(String body) {
  final plain = utf8.decode(decodePlaybackResponse(body));
  final response = decodeJsonObject(plain);
  if (response == null) {
    throw HongguoRequestException('红果备用播放接口返回了无效数据');
  }

  // `parse` / `jx` 是「要不要再解析一层」的标记位，为真表示这里拿不到直链。
  bool falsy(Object? value) {
    if (value == null) return true;
    if (value is bool) return !value;
    if (value is num) return value == 0;
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ||
          text == '0' ||
          text == 'false' ||
          text == 'null';
    }
    return false;
  }

  for (final flag in const ['parse', 'jx']) {
    if (falsy(response[flag])) continue;
    throw HongguoRequestException('红果备用播放接口没有返回直接媒体地址');
  }

  Media? selected;
  var bestQuality = -1;
  HongguoProtocolException? keyError;
  final variants = <Media>[];

  for (final option in anyList(response['key_urls'])) {
    if (option is! Map<String, dynamic>) continue;
    final mediaUrl = mapString(option, const ['src']).trim();
    if (mediaUrl.length > 8192 || !isHttpMediaUrl(mediaUrl)) continue;

    final keyId = hexDecode(mapString(option, const ['kid']).trim());
    if (keyId == null || keyId.length != 16) {
      keyError = HongguoProtocolException('红果媒体密钥标识无效');
      continue;
    }

    Uint8List key;
    try {
      key = contentKey(mapString(option, const ['spade_a']));
    } on HongguoProtocolException catch (error) {
      keyError = error;
      continue;
    }

    final quality = qualityFromText(mapString(option, const ['name']));
    final media = Media(
      url: mediaUrl,
      referer: mediaReferer,
      cencKey: key,
      quality: quality,
    );
    variants.add(media);
    if (selected == null || quality > bestQuality) {
      selected = media;
      bestQuality = quality;
    }
  }

  if (selected != null) {
    return Media(
      url: selected.url,
      referer: selected.referer,
      duration: selected.duration,
      cencKey: selected.cencKey,
      quality: selected.quality,
      variants: variants,
    );
  }
  if (keyError != null) throw HongguoRequestException(keyError.message);
  throw HongguoRequestException(
    '红果备用播放接口未返回该集可用的媒体和密钥，请稍后重试或确认该集是否仍可访问',
  );
}

/// 网页与备用两路的客户端方法，以及三级回退。对照 Go `hongguo/media.go`。
extension HongguoMediaTiersApi on HongguoClient {
  /// 网页单路取流。对照 Go 的 `Client.ResolveWebMedia`。
  ///
  /// 网页这条路经常是**明文**——正是 CENC 解不开时的兜底。
  Future<Media> resolveWebMedia(String seriesId, String videoId) async {
    final base = trimTrailingSlash(webBase);
    final body = await fetchText(
      '$base/player/${Uri.encodeComponent(seriesId)}/${Uri.encodeComponent(videoId)}',
      referer: '$base/',
    );
    return parseWebMedia(body, seriesId, videoId);
  }

  /// 备用接口单路取流。对照 Go 的 `Client.ResolvePlaybackAPI`。
  ///
  /// **这是第三方域名**（`djapi.999888456.xyz`），它能看到你请求了哪一集。只在
  /// 这个 APK 不外发的前提下成立——见 `docs/adr/0004`。
  Future<Media> resolvePlaybackApi(String seriesId, String videoId) async {
    if (!numericIdPattern.hasMatch(seriesId) ||
        !numericIdPattern.hasMatch(videoId)) {
      throw HongguoRequestException('红果播放请求缺少有效的剧集 ID');
    }
    final reference = jsonEncode(<String, Object?>{
      'content_type': 1004,
      'from_video_id': '',
      'series_id': seriesId,
      'vid': videoId,
      'video_platform': 3,
    });
    final id = base64.encode(utf8.encode(reference));
    final body = await fetchText(
      '$playbackApiUrl?id=${Uri.encodeComponent(id)}',
      referer: '${trimTrailingSlash(webBase)}/',
    );
    return parsePlaybackApi(body);
  }

  /// 三级取流：App 签名 → 网页 → 备用。对照 Go 的 `Client.ResolveMedia`。
  ///
  /// 三级都失败才报错，且错误里带上每一路的失败原因——不然线上出问题只能看到
  /// 最后一路的抱怨。
  Future<Media> resolveMedia(String seriesId, String videoId) async {
    if (!numericIdPattern.hasMatch(seriesId) ||
        !numericIdPattern.hasMatch(videoId)) {
      throw HongguoRequestException('红果章节 ID 无效，请重新获取章节');
    }

    Object? appError;
    try {
      return await resolveAppMedia(videoId);
    } catch (error) {
      appError = error;
    }

    Object? webError;
    try {
      return await resolveWebMedia(seriesId, videoId);
    } catch (error) {
      webError = error;
    }

    try {
      return await resolvePlaybackApi(seriesId, videoId);
    } catch (apiError) {
      throw HongguoRequestException(
        '红果 App 取流失败：$appError；网页取流失败：$webError；备用取流失败：$apiError',
      );
    }
  }
}
