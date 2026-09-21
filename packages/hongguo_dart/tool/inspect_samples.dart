// 开发用探针：定位视频轨第一个样本，看它的 NAL 长度前缀是明文还是密文。
//
//   dart run tool/inspect_samples.dart
//
// 为什么这是决定性的：media3 的 Mp4Extractor 在 nalUnitLengthFieldLength != 0 时
// 会无条件把 length-prefixed NAL 转成 Annex-B，代码里没有任何加密分支。所以只要
// 前缀是密文，就会读出负数长度并抛 "Invalid NAL length" —— 补 pssh、换 DRM 都没用。
//
//   · 前缀像样（值约等于 sampleSize-4）→ 明文 → ExoPlayer 那条路还能走。
//   · 前缀随机                      → 密文 → 只能预解密。
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

void main(List<String> args) async {
  final client = HongguoClient();
  final ids = args.isNotEmpty ? args : await _discover(client);
  if (ids.isEmpty) {
    stdout.writeln('挖不到 series_id');
    return;
  }

  final detail = await client.fetchDetail(ids.first);
  final episode = detail.episodes.first;
  final media = await client.resolveAppMedia(episode.videoId);
  stdout.writeln('剧：${detail.drama.title}｜第 1 集 vid=${episode.videoId}');

  final response = await client.http.get<List<int>>(
    media.url,
    options: Options(
      headers: {
        'Referer': media.referer,
        'User-Agent': webUserAgent,
        'Range': 'bytes=0-524287',
      },
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );
  final data = Uint8List.fromList(response.data ?? const <int>[]);
  stdout.writeln('拿到 ${data.length} 字节');

  final moov = _findBox(data, 0, data.length, 'moov');
  if (moov == null) {
    stdout.writeln('没有 moov');
    return;
  }

  for (final trak in _childrenOf(data, moov).where((b) => b.type == 'trak')) {
    _reportTrack(data, trak);
  }
}

void _reportTrack(Uint8List data, Box trak) {
  final stbl = _descend(data, trak, const ['mdia', 'minf', 'stbl']);
  if (stbl == null) return;

  var handler = '?';
  final hdlr = _descend(data, trak, const ['mdia', 'hdlr']);
  if (hdlr != null) {
    handler = String.fromCharCodes(
      data.sublist(hdlr.payloadStart + 8, hdlr.payloadStart + 12),
    );
  }

  final sizes = <int>[];
  final stsz = _childOf(data, stbl, 'stsz');
  if (stsz != null) {
    final sampleSize = _u32(data, stsz.payloadStart + 4);
    final count = _u32(data, stsz.payloadStart + 8);
    if (sampleSize == 0) {
      for (var i = 0; i < 3 && i < count; i++) {
        sizes.add(_u32(data, stsz.payloadStart + 12 + i * 4));
      }
    } else {
      sizes.addAll(List<int>.filled(3, sampleSize));
    }
  }

  final offsets = <int>[];
  final stco = _childOf(data, stbl, 'stco');
  final co64 = _childOf(data, stbl, 'co64');
  if (stco != null) {
    for (var i = 0; i < 3; i++) {
      offsets.add(_u32(data, stco.payloadStart + 8 + i * 4));
    }
  } else if (co64 != null) {
    for (var i = 0; i < 3; i++) {
      offsets.add(_u64(data, co64.payloadStart + 8 + i * 8));
    }
  }

  stdout.writeln('--- trak handler=$handler ---');
  stdout.writeln('  前几个样本 size=$sizes');
  stdout.writeln('  前几个 chunk offset=$offsets');
  if (offsets.isEmpty) return;

  final first = offsets.first;
  if (first + 16 > data.length) {
    stdout.writeln('  第一个 chunk 超出本次探测范围（@$first）');
    return;
  }
  final head = data.sublist(first, first + 16);
  final nals = <int>[];
  for (var i = 0; i + 4 <= head.length; i += 4) {
    nals.add(_u32(head, i));
  }
  stdout.writeln('  第一个 chunk 起 16 字节：${_hex(head)}');
  stdout.writeln('  按 4 字节读出的 NAL 长度：$nals');
  final looksClear = nals.first > 0 && nals.first < 100000 && nals.length > 1;
  stdout.writeln('  判定：${looksClear ? '前缀像是明文' : '前缀是密文（或非 NAL 结构）'}');

  // senc / saiz / saio 决定解密器怎么写：IV 多长、有没有 subsample。
  final senc = _childOf(data, stbl, 'senc');
  if (senc != null) {
    final payload = senc.payloadStart;
    final version = data[payload];
    final flags = _u24(data, payload + 1);
    stdout.writeln('  senc version=$version flags=0x${flags.toRadixString(16)} '
        'sample_count=${_u32(data, payload + 4)}');
    final end = payload + 8 + 48;
    if (end <= data.length) {
      stdout.writeln('  senc 紧随的 48 字节：${_hex(data.sublist(payload + 8, end))}');
    }
  }
  final saiz = _childOf(data, stbl, 'saiz');
  if (saiz != null) {
    final payload = saiz.payloadStart;
    stdout.writeln('  saiz default_sample_info_size=${data[payload + 4]} '
        'sample_count=${_u32(data, payload + 5)} '
        'flags=0x${_u24(data, payload + 1).toRadixString(16)}');
  }
  final saio = _childOf(data, stbl, 'saio');
  if (saio != null) {
    final payload = saio.payloadStart;
    final flags = _u24(data, payload + 1);
    final skip = (flags & 1) != 0 ? 8 : 0;
    stdout.writeln('  saio flags=0x${flags.toRadixString(16)} '
        'entry_count=${_u32(data, payload + 4 + skip)}');
  }
}

/// 按容器盒子逐层往下找。
Box? _descend(Uint8List data, Box from, List<String> path) {
  var current = from;
  for (final name in path) {
    final next = _childOf(data, current, name);
    if (next == null) return null;
    current = next;
  }
  return current;
}

class Box {
  Box(this.type, this.start, this.size);

  final String type;
  final int start;
  final int size;

  int get payloadStart => start + 8;
  int get end => start + size;
}

Box? _findBox(Uint8List data, int from, int to, String type) {
  for (final box in _childrenIn(data, from, to)) {
    if (box.type == type) return box;
  }
  return null;
}

Box? _childOf(Uint8List data, Box parent, String type) =>
    _findBox(data, parent.payloadStart, parent.end, type);

List<Box> _childrenOf(Uint8List data, Box parent) =>
    _childrenIn(data, parent.payloadStart, parent.end);

List<Box> _childrenIn(Uint8List data, int from, int to) {
  final out = <Box>[];
  var offset = from;
  while (offset + 8 <= to && offset + 8 <= data.length) {
    var size = _u32(data, offset);
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    if (size == 1) {
      // 64 位长度
      if (offset + 16 > data.length) break;
      size = _u64(data, offset + 8);
    } else if (size == 0) {
      size = to - offset;
    }
    if (size < 8) break;
    out.add(Box(type, offset, size));
    offset += size;
  }
  return out;
}

int _u32(Uint8List data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

int _u24(Uint8List data, int offset) =>
    (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];

int _u64(Uint8List data, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | data[offset + i];
  }
  return value;
}

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
  return found.take(2).toList();
}
