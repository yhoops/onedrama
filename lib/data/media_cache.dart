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

String episodeCacheFileName(String videoId) =>
    '$episodeCachePrefix$videoId$episodeCacheSuffix';

/// 缓存文件路径。播放页与设置页都用它。
Future<File> episodeCacheFile(String videoId) async {
  final directory = await getTemporaryDirectory();
  return File('${directory.path}/${episodeCacheFileName(videoId)}');
}

/// 清掉全部剧集缓存，返回删掉的文件数与释放的字节数。
Future<({int files, int bytes})> clearEpisodeCache() async {
  final directory = await getTemporaryDirectory();
  var files = 0;
  var bytes = 0;
  try {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (!name.startsWith(episodeCachePrefix) ||
          !name.endsWith(episodeCacheSuffix)) {
        continue;
      }
      try {
        bytes += await entity.length();
        await entity.delete();
        files++;
      } catch (_) {
        // 单个文件删不掉（偶尔被播放器占着）不该让整次清理失败。
      }
    }
  } catch (_) {
    // 目录不存在等情况，当作空处理。
  }
  return (files: files, bytes: bytes);
}

/// 当前剧集缓存占用。
Future<({int files, int bytes})> episodeCacheUsage() async {
  final directory = await getTemporaryDirectory();
  var files = 0;
  var bytes = 0;
  try {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (!name.startsWith(episodeCachePrefix) ||
          !name.endsWith(episodeCacheSuffix)) {
        continue;
      }
      try {
        bytes += await entity.length();
        files++;
      } catch (_) {}
    }
  } catch (_) {}
  return (files: files, bytes: bytes);
}

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
/// `docs/adr/0005`）。**代价是每次播放要先等整集下完**——短剧一集才两分钟、却要先下
/// 15 MB，这是当前最明显的体验短板。流式解密数据源是 `docs/plan.md` 的 4c。
///
/// 明文（网页 / 备用源）就不解密，直接存。
Future<File> prepareEpisode({
  required Dio dio,
  required Media media,
  required String videoId,
  void Function(int received, int total)? onProgress,
}) async {
  final target = await episodeCacheFile(videoId);
  if (await target.exists() && await target.length() > 1024) return target;

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

  // 先写临时文件再改名：中途失败/被杀不会留下半个文件被当成缓存命中。
  final temp = File('${target.path}.part');
  await temp.writeAsBytes(playable, flush: true);
  return temp.rename(target.path);
}
