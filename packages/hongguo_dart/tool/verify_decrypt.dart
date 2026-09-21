// 离线验证 CENC 解密。不需要手机。
//
//   dart run tool/verify_decrypt.dart [series_id]
//
// 两步：
//   1. 几何自检——所有样本的 [offset, end) 必须**严丝合缝铺满 mdat**，有洞或重叠
//      就说明 stsc/stsz/stco 走错了（症状和"密码学错了"一模一样，必须先排除）。
//   2. 枚举密码学变体——IV 放高 8 字节还是低 8 字节、CTR 还是 CBC、密钥要不要
//      反序、有没有明文前导。判据是 walkAvcc：明文 AVCC 样本必须能按 4 字节长度
//      前缀严丝合缝走完，密文必然走不完。
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

const int _fetchBytes = 1024 * 1024;
const int _checkPerTrack = 40;

Future<void> main(List<String> args) async {
  final client = HongguoClient();
  final ids = args.isNotEmpty ? args : await _discover(client);
  if (ids.isEmpty) {
    stdout.writeln('挖不到 series_id');
    return;
  }

  final detail = await client.fetchDetail(ids.first);
  final episode = detail.episodes.first;
  final media = await client.resolveAppMedia(episode.videoId);
  if (!media.isEncrypted) {
    stdout.writeln('这一集是明文');
    return;
  }

  final response = await client.http.get<List<int>>(
    media.url,
    options: Options(
      headers: {
        'Referer': media.referer,
        'User-Agent': webUserAgent,
        'Range': 'bytes=0-$_fetchBytes',
      },
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );
  final file = Uint8List.fromList(response.data ?? const <int>[]);
  stdout.writeln('剧：${detail.drama.title}｜vid=${episode.videoId}');
  stdout.writeln('key=${_hex(media.cencKey!)}｜拿到 ${file.length} 字节');

  // 落盘一份，好让 FFmpeg（原项目用的参考实现）来判 decrypt 是否正确。
  final dump = Platform.environment['DUMP'];
  if (dump != null && dump.isNotEmpty) {
    File(dump).writeAsBytesSync(file);
    stdout.writeln('已写入 $dump');
  }

  final index = CencIndex.parse(file);
  if (index == null) {
    stdout.writeln('解析不出 CENC 索引');
    return;
  }
  stdout.writeln('轨道=${index.tracks.map((t) => t.handler).toList()} '
      '样本=${index.samples.length}');

  _checkTiling(file, index);

  // 视频轨的 AVCC 结构是「解密对不对」的硬判据：明文样本必须能按 4 字节长度
  // 前缀严丝合缝走完。音频轨是裸 AAC，没有这种结构，走不通是正常的。
  var videoOk = 0;
  var videoBad = 0;
  for (final track in index.tracks) {
    var checked = 0;
    var ok = 0;
    var bad = 0;
    for (final sample in track.samples) {
      if (sample.end > file.length) break;
      if (checked >= _checkPerTrack) break;
      final plain = aesCtrDecrypt(
        media.cencKey!,
        sample.iv,
        Uint8List.sublistView(file, sample.offset, sample.end),
      );
      final walk = walkAvcc(plain);
      if (checked == 0) {
        stdout.writeln('  ${track.handler} #0 解密后头 16 字节：'
            '${_hex(plain.sublist(0, 16))} → avcc=${walk.ok} nal=${walk.nalUnits}');
      }
      if (walk.ok) {
        ok++;
      } else {
        bad++;
      }
      checked++;
    }
    stdout.writeln('trak ${track.handler}：检查 $checked，AVCC 走通 $ok 走不通 $bad');
    if (track.handler == 'vide') {
      videoOk = ok;
      videoBad = bad;
    }
  }

  stdout.writeln();
  if (videoOk > 0 && videoBad == 0) {
    stdout.writeln('结论：解密正确。算法 = AES-128-CTR，IV 放 counter 高 8 字节。');
  } else {
    stdout.writeln('结论：还没完全对。');
  }
}

/// 样本必须严丝合缝铺满 mdat。有洞或重叠说明 stsc/stsz/stco 走错了。
void _checkTiling(Uint8List file, CencIndex index) {
  final mdat = mp4Top(file, 'mdat');
  if (mdat == null) {
    stdout.writeln('几何自检：没有 mdat');
    return;
  }
  var cursor = mdat.payload;
  var gaps = 0;
  var overlaps = 0;
  var beyond = 0;
  for (final sample in index.samples) {
    if (sample.offset > cursor) gaps++;
    if (sample.offset < cursor) overlaps++;
    if (sample.end > mdat.end) beyond++;
    if (sample.end > cursor) cursor = sample.end;
  }
  stdout.writeln('几何自检：mdat=[${mdat.payload}, ${mdat.end}) '
      '铺到 $cursor｜洞=$gaps 重叠=$overlaps 越界=$beyond');
  if (gaps == 0 && overlaps == 0 && cursor == mdat.end) {
    stdout.writeln('  → 几何完全对齐。');
  } else {
    stdout.writeln('  → 几何没对齐，先修这个，密码学变体再多也没意义。');
  }
}

// 密码学部分在 lib/src/cenc.dart 的 aesCtrDecrypt 里，这里只做验证。
// 语义（实测确认）：AES-128-CTR，8 字节 IV 放 counter 块**高** 8 字节，
// 低 8 字节从 0 按大端递增，整个样本加密。

String _hex(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();

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
