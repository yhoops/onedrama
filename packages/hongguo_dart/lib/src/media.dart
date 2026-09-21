import 'dart:typed_data';

import 'client.dart';
import 'crypto.dart';
import 'ids.dart';
import 'json.dart';

/// 一集的可播放流。取值 `hongguo-cenc://{vid}` 那种占位地址**不是** Media。
class Media {
  const Media({
    required this.url,
    required this.referer,
    this.duration = Duration.zero,
    this.cencKey,
    this.quality = 0,
    this.width = 0,
    this.height = 0,
    this.variants = const <Media>[],
  });

  /// http(s) 播放地址。
  final String url;

  final String referer;
  final Duration duration;

  /// AES-128 CENC 密钥，null 表示未加密。本包只给密钥，不解封装。
  final Uint8List? cencKey;

  /// **档位标签**（来自 `definition`），约等于高度，如 720 / 1080。
  ///
  /// 它不是像素高——实测有剧把 1280x720 标成「1080p」，也有横屏剧的 480p 其实是
  /// 480x854。要真实尺寸用 [width] / [height]。
  final int quality;

  /// 真实像素宽高，来自 `video_meta` 的 `vwidth` / `vheight`（已与 ffprobe 逐档核对）。
  ///
  /// 0 表示上游没给——网页与备用源都不给，只有 App 源有。
  final int width;
  final int height;

  /// 同一集的其他画质。切换画质时本地换 URL + 密钥即可，不必重新取流。
  final List<Media> variants;

  bool get isEncrypted => cencKey != null && cencKey!.isNotEmpty;

  /// 显示用的宽高比。上游没给尺寸时是 null——调用方应当退回「铺满」而不是猜一个。
  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;
}

final RegExp _qualityNumber = RegExp(r'[0-9]+');

/// 从画质名里抠出数字（`1080P` → 1080）。抠不到返回 0。
int qualityFromText(String text) =>
    int.tryParse(_qualityNumber.firstMatch(text)?.group(0) ?? '') ?? 0;

/// 是不是可用的 http(s) 媒体地址。对照 Go 的 `IsHTTPMediaURL`。
bool isHttpMediaUrl(String raw) {
  final parsed = Uri.tryParse(raw.trim());
  if (parsed == null) return false;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return false;
  if (parsed.host.isEmpty) return false;
  if (parsed.userInfo.isNotEmpty) return false;
  return true;
}

/// 从 App 取流响应的 `video_model` 里选一路媒体。
///
/// 对照 Go 的 `SelectAppMedia`：跳过 `bytevc2`，同分辨率优先 H.264，有 `spade_a`
/// 时还原出 CENC 密钥。
Media selectAppMedia(Map<String, dynamic>? model) {
  if (model == null || model.isEmpty) {
    throw HongguoRequestException('红果 App 未返回兼容的媒体，已跳过不支持的编码');
  }

  var rows = anyList(model['video_list']);
  if (rows.isEmpty) {
    // 有些响应把画质挂在 map 上，key 是画质名。
    final map = model['video_list'];
    if (map is Map<String, dynamic>) {
      final keys = map.keys.toList()..sort();
      rows = [
        for (final key in keys)
          if (map[key] != null) map[key]!,
      ];
    }
  }

  final seconds = double.tryParse(
        mapString(model, const ['video_duration', 'duration']),
      ) ??
      0;
  final duration = Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );

  Media? selected;
  var bestQuality = -1;
  HongguoProtocolException? keyError;
  final choices = <int, Media>{};
  final scores = <int, int>{};

  for (final row in rows) {
    if (row is! Map<String, dynamic>) continue;

    final meta = nestedMap(row['video_meta'], const <String>[]);
    final codec = mapString(meta, const ['codec_type']).toLowerCase();
    if (codec == 'bytevc2' ||
        mapString(row, const ['gear_des_key']).toLowerCase().contains('bytevc2')) {
      continue;
    }

    final address = mapString(row, const ['main_url']);
    if (address.length > 8192 || !isHttpMediaUrl(address)) continue;

    Uint8List? cencKey;
    final encryption = nestedMap(row['encrypt_info'], const <String>[]);
    final spade = mapString(encryption, const ['spade_a']);
    if (spade.isNotEmpty ||
        encryption?['encrypt'] == true ||
        mapString(encryption, const ['encryption_method']) == 'cenc-aes-ctr') {
      try {
        cencKey = contentKey(spade);
      } on HongguoProtocolException catch (error) {
        keyError = error;
        continue;
      }
    }

    final width = int.tryParse(mapString(meta, const ['vwidth'])) ?? 0;
    final pixelHeight = int.tryParse(mapString(meta, const ['vheight'])) ?? 0;

    // `height` 是**档位标签**（会被 definition 覆盖），真实像素尺寸单独留着给播放页
    // 排版用——两者不是一回事，见 Media.quality 的注释。
    var height = pixelHeight;
    final definition = int.tryParse(
      _qualityNumber.firstMatch(mapString(meta, const ['definition']))?.group(0) ?? '',
    );
    if (definition != null && definition > 0) {
      height = definition;
    } else if (width > 0 && (height == 0 || width < height)) {
      height = width;
    }

    final media = Media(
      url: address,
      referer: mediaReferer,
      duration: duration,
      cencKey: cencKey,
      quality: height,
      width: width,
      height: pixelHeight,
    );

    var score = height * 10;
    if (codec == 'h264' || codec == 'avc1') score++;

    final previous = scores[height];
    if (previous == null || score > previous) {
      choices[height] = media;
      scores[height] = score;
    }
    if (selected == null || score > bestQuality) {
      selected = media;
      bestQuality = score;
    }
  }

  if (selected != null) {
    final variants = choices.values.toList()
      ..sort((left, right) => right.quality.compareTo(left.quality));
    return Media(
      url: selected.url,
      referer: selected.referer,
      duration: selected.duration,
      cencKey: selected.cencKey,
      quality: selected.quality,
      width: selected.width,
      height: selected.height,
      variants: variants,
    );
  }
  if (keyError != null) {
    throw HongguoRequestException('红果 App 媒体密钥不可用：$keyError');
  }
  throw HongguoRequestException('红果 App 未返回兼容的媒体，已跳过不支持的编码');
}

/// 取流相关的客户端方法。对照 Go `hongguo/media.go` 里挂在 `Client` 上的那几个。
extension HongguoMediaApi on HongguoClient {
  /// App 单路取流。对照 Go 的 `Client.ResolveAppMedia`。
  ///
  /// 网页与备用兜底是阶段 2 的事，见 `docs/plan.md`。
  Future<Media> resolveAppMedia(String videoId) async {
    if (!numericIdPattern.hasMatch(videoId)) {
      throw HongguoRequestException('红果视频 ID 无效');
    }
    final result = await appRequest(
      method: 'POST',
      path: '/novel/player/video_model/v1/',
      payload: {
        'video_id': videoId,
        'content_type': 1,
        'biz_param': {'need_all_video_definition': true, 'video_platform': 3},
      },
    );
    final data = nestedMap(result, const ['data']) ?? const <String, dynamic>{};
    var model = data['video_model'];
    if (model is String) model = decodeJsonObject(model);
    return selectAppMedia(model is Map<String, dynamic> ? model : null);
  }
}
