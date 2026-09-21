import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:path_provider/path_provider.dart';

/// 解密后的剧集落盘缓存（播放页写的 `cenc_<vid>.mp4`）。
///
/// 这些文件占了 App 绝大部分磁盘占用，「设置 → 剧库与存储 → 清除缓存」主要清的就是
/// 它们。所以单独放一个文件，让播放页与设置页共用同一套命名规则——命名一旦分叉，
/// 清理就会漏。
const String episodeCachePrefix = 'cenc_';
const String episodeCacheSuffix = '.mp4';

/// 取流结果的**旁挂**文件（sidecar）。
///
/// 预取下一集时顺手把「这一集有哪些档位、当时下的是哪一档」也存下来。没有它，切集时
/// 就得再打一次签名请求——而那次请求的**唯一**用途是拿宽高与档位列表给界面排版，URL
/// 根本用不上（播的是本地文件）。见 `docs/adr/0009`。
const String episodeSidecarSuffix = '.json';

/// 预取保留的集数。更早的连旁挂一起淘汰——不指望 Android 在空间紧张时回收兜底。
const int episodeCacheKeep = 10;

String episodeCacheFileName(String videoId) =>
    '$episodeCachePrefix$videoId$episodeCacheSuffix';

String episodeSidecarFileName(String videoId) =>
    '$episodeCachePrefix$videoId$episodeSidecarSuffix';

/// 缓存文件路径。播放页与设置页都用它。
Future<File> episodeCacheFile(String videoId) async {
  final directory = await getTemporaryDirectory();
  return File('${directory.path}/${episodeCacheFileName(videoId)}');
}

Future<File> _sidecarFile(String videoId) async =>
    _sidecarFileIn(await getTemporaryDirectory(), videoId);

File _sidecarFileIn(Directory directory, String videoId) =>
    File('${directory.path}/${episodeSidecarFileName(videoId)}');

/// 带这个前缀的文件都是我们的（剧集 / 旁挂 / 下载中的 `.part`）。
///
/// 一律按前缀认领，不逐个后缀列举：列举式的话，将来多一种后缀就多一处漏——`.part`
/// 就差点成了「清缓存清不掉的垃圾」。
bool _isCacheEntry(String name) => name.startsWith(episodeCachePrefix);

/// 只有 `.mp4` 才算「一集」。占用与计数都用它，旁挂是零头。
bool _isEpisodeFile(String name) =>
    name.startsWith(episodeCachePrefix) && name.endsWith(episodeCacheSuffix);

bool _isSidecar(String name) =>
    name.startsWith(episodeCachePrefix) && name.endsWith(episodeSidecarSuffix);

String _baseName(FileSystemEntity entity) =>
    entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;

/// 从 `cenc_<vid>.mp4` 反推 videoId。不认识的返回空串。
String _videoIdOf(String fileName) {
  if (!_isEpisodeFile(fileName)) return '';
  return fileName.substring(
    episodeCachePrefix.length,
    fileName.length - episodeCacheSuffix.length,
  );
}

/// 从 `cenc_<vid>.json` 反推 videoId。不认识的返回空串。
String _videoIdOfSidecar(String fileName) {
  if (!_isSidecar(fileName)) return '';
  return fileName.substring(
    episodeCachePrefix.length,
    fileName.length - episodeSidecarSuffix.length,
  );
}

/// 清掉全部剧集缓存（含旁挂与半截的 `.part`），返回删掉的**集数**与释放的字节数。
///
/// [directory] 只给测试用：单测里没有 `path_provider` 的平台通道。
Future<({int files, int bytes})> clearEpisodeCache({Directory? directory}) async {
  final dir = directory ?? await getTemporaryDirectory();
  var files = 0;
  var bytes = 0;
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = _baseName(entity);
      if (!_isCacheEntry(name)) continue;
      try {
        bytes += await entity.length();
        await entity.delete();
        if (_isEpisodeFile(name)) files++;
      } catch (_) {
        // 单个文件删不掉（偶尔被播放器占着）不该让整次清理失败。
      }
    }
  } catch (_) {
    // 目录不存在等情况，当作空处理。
  }
  return (files: files, bytes: bytes);
}

/// 当前剧集缓存占用。集数只数 `.mp4`，字节数**含旁挂与 `.part`**——同一个数字要能
/// 回答「按下去会腾出多少」，而清理是把它们一起清掉的。
Future<({int files, int bytes})> episodeCacheUsage({Directory? directory}) async {
  final dir = directory ?? await getTemporaryDirectory();
  var files = 0;
  var bytes = 0;
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = _baseName(entity);
      if (!_isCacheEntry(name)) continue;
      try {
        bytes += await entity.length();
        if (_isEpisodeFile(name)) files++;
      } catch (_) {}
    }
  } catch (_) {}
  return (files: files, bytes: bytes);
}

/// 只留最近 [keep] 集，更早的连旁挂一起删；顺手清掉没有剧集文件的孤儿旁挂。
///
/// 按**文件时间**排序，不按集号：预取是随时发生的，同一部剧的集号未必与下载先后一致
/// （用户可能跳着选集）。[protect] 里的 videoId 永不淘汰——正在播的那一集不能被删。
///
/// 返回淘汰掉的集数。[directory] 只给测试用。
Future<int> pruneEpisodeCache({
  Directory? directory,
  int keep = episodeCacheKeep,
  Set<String> protect = const <String>{},
}) async {
  final dir = directory ?? await getTemporaryDirectory();
  final episodes = <({String videoId, DateTime at})>[];
  final sidecars = <String>{};
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = _baseName(entity);
      if (!_isCacheEntry(name)) continue;
      if (_isEpisodeFile(name)) {
        try {
          episodes.add((
            videoId: _videoIdOf(name),
            at: (await entity.stat()).modified,
          ));
        } catch (_) {}
      } else if (_isSidecar(name)) {
        sidecars.add(_videoIdOfSidecar(name));
      }
      // `.part` 一律不碰：那是正在下的东西，删了会让下载以奇怪的方式失败。
    }
  } catch (_) {
    return 0;
  }

  episodes.sort((left, right) => right.at.compareTo(left.at));
  final kept = <String>{for (final entry in episodes) entry.videoId};

  var removed = 0;
  for (var index = keep; index < episodes.length; index++) {
    final videoId = episodes[index].videoId;
    if (protect.contains(videoId)) continue;
    if (await _deleteEpisode(videoId, directory: dir)) removed++;
  }
  for (final videoId in sidecars.difference(kept)) {
    if (protect.contains(videoId)) continue;
    try {
      final file = _sidecarFileIn(dir, videoId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
  return removed;
}

/// 删掉一集的缓存文件与旁挂。返回是否真的删掉了东西。
Future<bool> _deleteEpisode(String videoId, {Directory? directory}) async {
  final dir = directory ?? await getTemporaryDirectory();
  var removed = false;
  for (final file in [
    File('${dir.path}/${episodeCacheFileName(videoId)}'),
    _sidecarFileIn(dir, videoId),
  ]) {
    try {
      if (await file.exists()) {
        await file.delete();
        removed = true;
      }
    } catch (_) {}
  }
  return removed;
}

/// 删掉某一集的缓存（含旁挂）。
///
/// 用户在播放页**手动换画质**时用它：磁盘上那份是预取时挑的档，跟新选的档不是一回事，
/// 留着会让「下次再看这一集」莫名其妙地退回旧画质。
Future<void> dropEpisodeCache(String videoId) => _deleteEpisode(videoId);

/// 人类可读的体积。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 下载整集并解密落盘，返回可直接播放的本地文件。
///
/// 复用协议包里已离线验证过的那条路（样本索引 + 等长替换补丁 + AES-CTR，见
/// `docs/adr/0005`）。明文（网页 / 备用源）就不解密，直接存。
///
/// [cancelToken] 给预取用——退出播放页时把在飞的那次下载停掉，别白下 14.6 MB。
Future<File> prepareEpisode({
  required Dio dio,
  required Media media,
  required String videoId,
  void Function(int received, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  final target = await episodeCacheFile(videoId);
  if (await target.exists() && await target.length() > 1024) return target;

  // 先写临时文件再改名：中途失败/被杀不会留下半个文件被当成缓存命中。
  final temp = File('${target.path}.part');
  try {
    final response = await dio.get<List<int>>(
      media.url,
      options: Options(
        headers: <String, String>{
          'Referer': media.referer,
          'User-Agent': webUserAgent,
        },
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );

    final raw = Uint8List.fromList(response.data ?? const <int>[]);
    if (raw.length < 1024) {
      throw HongguoRequestException('这一集只拿到 ${raw.length} 字节，不像完整内容');
    }

    Uint8List playable = raw;
    if (media.isEncrypted) {
      final index = CencIndex.parse(raw);
      if (index == null) {
        throw HongguoProtocolException('这一集解不出 CENC 索引，可能站点改了封装');
      }
      playable = decryptToClearFile(
        key: media.cencKey!,
        index: index,
        file: raw,
        patches: buildNeutralizingPatches(raw),
      );
    }

    await temp.writeAsBytes(playable, flush: true);
    return await temp.rename(target.path);
  } catch (_) {
    // 取消或失败都不留半截 `.part`：它永远不会被当成缓存命中（命名不同），却会一直
    // 占着几 MB，而且是「清除缓存」清不掉的假象——现在清得掉，但根本不该产生。
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  }
}

// ---------- 旁挂：预取时把取流结果一起存下来 ----------

/// 写一份旁挂。见 [episodeSidecarFileName]。
///
/// [media] 是取流返回的**外层**结果（带全部档位），[pickedQuality] 是实际下载的那一档。
Future<void> writeEpisodeSidecar(
  String videoId, {
  required Media media,
  required int pickedQuality,
  Directory? directory,
}) async {
  final payload = <String, Object?>{
    'version': 1,
    'picked': pickedQuality,
    'variants': [for (final variant in _allVariants(media)) _mediaToJson(variant)],
  };
  final file = directory == null
      ? await _sidecarFile(videoId)
      : _sidecarFileIn(directory, videoId);
  final temp = File('${file.path}.part');
  await temp.writeAsString(jsonEncode(payload), flush: true);
  await temp.rename(file.path);
}

/// 读回旁挂。没有 / 坏了都返回 null——调用方退回「老老实实打一次取流」。
///
/// 返回的是**当时下载的那一档**（带着完整档位列表），所以调用方不该再拿设置里的
/// 偏好去挑一遍：磁盘上就那一档，重挑只会让标签和画面对不上。
Future<Media?> readEpisodeSidecar(String videoId, {Directory? directory}) async {
  try {
    final file = directory == null
        ? await _sidecarFile(videoId)
        : _sidecarFileIn(directory, videoId);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) return null;

    final rawVariants = decoded['variants'];
    if (rawVariants is! List) return null;
    final variants = <Media>[];
    for (final raw in rawVariants) {
      if (raw is! Map<String, dynamic>) continue;
      final media = _mediaFromJson(raw);
      if (media != null) variants.add(media);
    }
    if (variants.isEmpty) return null;

    final picked = (decoded['picked'] as num?)?.toInt() ?? 0;
    final chosen = variants.firstWhere(
      (media) => media.quality == picked,
      orElse: () => variants.first,
    );
    return Media(
      url: chosen.url,
      referer: chosen.referer,
      duration: chosen.duration,
      cencKey: chosen.cencKey,
      quality: chosen.quality,
      width: chosen.width,
      height: chosen.height,
      variants: variants,
    );
  } catch (_) {
    // 旁挂坏了不该让这一集播不了——返回 null，调用方会走网络。
    return null;
  }
}

/// 外层结果自己 + 它的档位。外层与档位是同一批，去重按 URL。
List<Media> _allVariants(Media media) {
  final out = <Media>[];
  final seen = <String>{};
  for (final variant in <Media>[
    media,
    ...media.variants,
  ]) {
    if (variant.url.isEmpty || !seen.add(variant.url)) continue;
    out.add(variant);
  }
  return out;
}

Map<String, Object?> _mediaToJson(Media media) => <String, Object?>{
  'url': media.url,
  'referer': media.referer,
  'durationMs': media.duration.inMilliseconds,
  'key': media.cencKey == null ? null : _hexOf(media.cencKey!),
  'quality': media.quality,
  'width': media.width,
  'height': media.height,
};

Media? _mediaFromJson(Map<String, dynamic> json) {
  final url = json['url'];
  if (url is! String || url.isEmpty) return null;
  final rawKey = json['key'];
  final key = rawKey is String && rawKey.isNotEmpty ? _bytesOfHex(rawKey) : null;
  return Media(
    url: url,
    referer: json['referer'] as String? ?? '',
    duration: Duration(
      milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
    ),
    cencKey: key,
    quality: (json['quality'] as num?)?.toInt() ?? 0,
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
  );
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();

Uint8List _bytesOfHex(String hex) {
  final clean = hex.trim();
  if (clean.length.isOdd) return Uint8List(0);
  final out = Uint8List(clean.length ~/ 2);
  for (var index = 0; index < out.length; index++) {
    final value = int.tryParse(clean.substring(index * 2, index * 2 + 2), radix: 16);
    if (value == null) return Uint8List(0);
    out[index] = value;
  }
  return out;
}
