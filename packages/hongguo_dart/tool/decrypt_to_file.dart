// 把整集解开成一份干净 MP4，交给 FFmpeg 判「抹平加密痕迹」这一步对不对。
//
//   mkdir -p E:/Env/tmp/cenc
//   dart run tool/decrypt_to_file.dart E:/Env/tmp/cenc/clear.mp4
//   ffmpeg -i E:/Env/tmp/cenc/clear.mp4 -frames:v 30 -f null -
//
// 判据：不带任何密钥，FFmpeg 能正常解码出帧（带 -decryption_key 才解得出的是密文，
// 不加就解得出的才是真明文）。
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

Future<void> main(List<String> args) async {
  final target = args.isNotEmpty ? args[0] : 'E:/Env/tmp/cenc/clear.mp4';
  final client = HongguoClient();
  final ids = args.length > 1 ? <String>[args[1]] : await _discover(client);
  if (ids.isEmpty) {
    stdout.writeln('挖不到 series_id');
    return;
  }

  final detail = await client.fetchDetail(ids.first);
  final episode = detail.episodes.first;
  final media = await client.resolveAppMedia(episode.videoId);
  if (!media.isEncrypted) {
    stdout.writeln('这一集是明文，不需要解');
    return;
  }
  stdout.writeln('剧：${detail.drama.title}｜vid=${episode.videoId}');

  // 全量下载。注意不能带 Range——要完整 moov + 完整 mdat。
  final response = await client.http.get<List<int>>(
    media.url,
    options: Options(
      headers: {
        'Referer': media.referer,
        'User-Agent': webUserAgent,
      },
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );
  final file = Uint8List.fromList(response.data ?? const <int>[]);
  stdout.writeln('下载 ${file.length} 字节（HTTP ${response.statusCode}）');
  if (file.length < 1024) {
    stdout.writeln('太小了，不像一整集');
    return;
  }

  final index = CencIndex.parse(file);
  if (index == null) {
    stdout.writeln('解析不出 CENC 索引');
    return;
  }
  stdout.writeln('轨道=${index.tracks.map((t) => t.handler).toList()} '
      '样本=${index.samples.length}');

  final patches = buildNeutralizingPatches(file);
  stdout.writeln('等长替换补丁 ${patches.length} 处：');
  for (final patch in patches) {
    final preview = patch.bytes.sublist(4, patch.bytes.length < 16 ? patch.bytes.length : 16);
    stdout.writeln('  @${patch.offset} ${patch.bytes.length}B '
        '类型=${String.fromCharCodes(preview)}');
  }

  final clear = decryptToClearFile(
    key: media.cencKey!,
    index: index,
    file: file,
    patches: patches,
  );
  File(target).writeAsBytesSync(clear);
  stdout.writeln('已写入 $target（${clear.length} 字节，与输入等长 '
      '${clear.length == file.length}）');
}

Future<List<String>> _discover(HongguoClient client) async {
  final url = '$webBaseUrl/incent_resource/suggestion'
      '?app_id=$appAid&query=${Uri.encodeQueryComponent('总裁')}&count=10';
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
    final id =
        dramaFromAny(nestedMap(map, const ['video_data']) ?? map).sourceId;
    if (id.isNotEmpty && !found.contains(id)) found.add(id);
  }
  return found.take(1).toList();
}
