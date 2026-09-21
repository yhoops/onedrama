// 开发用探针：验尸一集真实媒体流，判断它到底是哪种加密。
//
//   dart run tool/inspect_media.dart
//
// 这一步决定 Kotlin 侧走哪条路：
//   - 有 pssh / senc / tenc → 标准 CENC（逐样本 IV、subsample），需要 MediaDrm 或
//     CENC 感知的数据源；AesCipherDataSource 那种整段 AES-CTR 处理不了。
//   - 只有 sinf/schm 没 senc  → 可能是整段加密，AesCipherDataSource 可用。
//   - 什么都没有            → 明文，不需要解密。
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

const int _probeBytes = 512 * 1024;

Future<void> main(List<String> args) async {
  final client = HongguoClient();
  final ids = args.isNotEmpty ? args : await _discover(client);
  if (ids.isEmpty) {
    stdout.writeln('挖不到 series_id');
    return;
  }

  final detail = await client.fetchDetail(ids.first);
  stdout.writeln('剧：${detail.drama.title}｜${detail.episodes.length} 集');

  final episode = detail.episodes.first;
  final media = await client.resolveAppMedia(episode.videoId);
  stdout.writeln('vid=${episode.videoId} 画质=${media.quality} '
      '加密=${media.isEncrypted} 备选=${media.variants.length}');
  stdout.writeln('KEY=${media.cencKey == null ? '-' : _hex(media.cencKey!)}');
  stdout.writeln('URL=${media.url}');
  stdout.writeln('Referer=${media.referer}');

  final response = await client.http.get<List<int>>(
    media.url,
    options: Options(
      headers: {
        'Referer': media.referer,
        'User-Agent': webUserAgent,
        'Range': 'bytes=0-$_probeBytes',
      },
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );
  final body = Uint8List.fromList(response.data ?? const <int>[]);
  stdout.writeln('HTTP=${response.statusCode} 收到 ${body.length} 字节');

  _walkTopLevelBoxes(body);
  _scanForCryptoBoxes(body);
}

/// 按 size(4) + type(4) 走顶层盒子。
void _walkTopLevelBoxes(Uint8List data) {
  stdout.writeln('--- 顶层盒子 ---');
  var offset = 0;
  while (offset + 8 <= data.length) {
    final size = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    stdout.writeln('  $type  size=$size  @$offset');
    if (size < 8) {
      stdout.writeln('  （size 异常，停）');
      return;
    }
    offset += size;
    if (offset >= data.length) break;
  }
}

/// 在缓冲区里数加密相关盒子的出现次数，并把能读的字段读出来。
void _scanForCryptoBoxes(Uint8List data) {
  const names = [
    'senc', 'tenc', 'saiz', 'saio', 'pssh', 'sinf', 'schm', 'schi',
    'cenc', 'cbcs', 'cbc1', 'cens', 'frma',
  ];
  stdout.writeln('--- 加密盒子扫描（前 ${data.length} 字节）---');
  for (final name in names) {
    final hits = _countOccurrences(data, name);
    if (hits > 0) {
      final first = _firstOccurrence(data, name);
      stdout.writeln('  $name × $hits，首次 @$first');
    }
  }
  _parseSchm(data);
  _parseTenc(data);
  _dumpTencBytes(data);
  _walkMoovChildren(data);
  _inspectMdat(data);
}

/// 走 moov 的直接子盒子。
///
/// 关心的不是结构好看，而是：有没有一个够大的可丢弃盒子，能原地换成 `pssh`。
/// 换等大就移动不了 mdat，stco 的绝对偏移不用重算。
void _walkMoovChildren(Uint8List data) {
  final typeAt = _firstOccurrence(data, 'moov');
  if (typeAt < 4) return;
  final moovStart = typeAt - 4;
  final moovSize = _readU32(data, moovStart);
  final moovEnd = moovStart + moovSize;
  stdout.writeln('--- moov 子盒子（size=$moovSize）---');
  var offset = typeAt + 4;
  while (offset + 8 <= moovEnd && offset + 8 <= data.length) {
    final size = _readU32(data, offset);
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    stdout.writeln('  $type  size=$size  @$offset');
    if (size < 8) {
      stdout.writeln('  （size 异常，停）');
      return;
    }
    offset += size;
  }
  if (moovEnd > data.length) {
    stdout.writeln('  （moov 尾部超出本次探测范围，只列了能读到的）');
  }
}

int _readU32(Uint8List data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

/// 把 tenc 附近的原始字节打出来。偏移猜错一位结论就会反过来，所以要看原始值。
void _dumpTencBytes(Uint8List data) {
  final index = _firstOccurrence(data, 'tenc');
  if (index < 4) return;
  final start = index - 4; // 从 size 字段开始
  final end = start + 44 < data.length ? start + 44 : data.length;
  stdout.writeln('--- tenc 原始字节（size 字段起 44 字节）---');
  stdout.writeln('  ${_hex(data.sublist(start, end))}');
}

/// 看 mdat 里的视频到底是明文 NAL 还是密文。
///
/// 明文 H.264/HEVC 到处是起始码 00 00 01 / 00 00 00 01；密文里几乎不会出现。
void _inspectMdat(Uint8List data) {
  const mdat = 'mdat';
  final index = _firstOccurrence(data, mdat);
  if (index < 0) {
    stdout.writeln('--- 这一段里没有 mdat ---');
    return;
  }
  final start = index + 4;
  if (start + 65536 > data.length) {
    stdout.writeln('--- mdat 数据不足 64KB，无法判断 ---');
    return;
  }
  final sample = data.sublist(start, start + 65536);
  var threeByte = 0;
  var fourByte = 0;
  for (var i = 0; i + 3 < sample.length; i++) {
    if (sample[i] == 0 && sample[i + 1] == 0) {
      if (sample[i + 2] == 1) threeByte++;
      if (i + 4 < sample.length && sample[i + 2] == 0 && sample[i + 3] == 1) {
        fourByte++;
      }
    }
  }
  final zeroBytes = sample.where((b) => b == 0).length;
  final zeroRatio = zeroBytes / sample.length;
  stdout.writeln('--- mdat 前 64KB ---');
  stdout.writeln('  00 00 01 起始码 × $threeByte｜00 00 00 01 起始码 × $fourByte');
  stdout.writeln('  零字节占比 ${(zeroRatio * 100).toStringAsFixed(2)}%'
      '（明文视频通常 20%+；密文接近 0.4%）');
  stdout.writeln('  头 32 字节：${_hex(sample.sublist(0, 32))}');
}

/// `schm`：保护方案与版本。scheme_type 应该是 `cenc` / `cbcs`。
void _parseSchm(Uint8List data) {
  final index = _firstOccurrence(data, 'schm');
  if (index < 0 || index + 16 > data.length) return;
  final base = index + 4; // 跳过类型名，payload 从这里开始
  final schemeType = String.fromCharCodes(data.sublist(base + 4, base + 8));
  final schemeVersion = (data[base + 8] << 24) |
      (data[base + 9] << 16) |
      (data[base + 10] << 8) |
      data[base + 11];
  stdout.writeln('--- schm ---');
  stdout.writeln('  scheme_type=$schemeType '
      'scheme_version=0x${schemeVersion.toRadixString(16).padLeft(8, '0')}');
}

/// `tenc`：默认加密参数。per-sample IV 大小与 KID 决定解密怎么做。
void _parseTenc(Uint8List data) {
  final index = _firstOccurrence(data, 'tenc');
  if (index < 0 || index + 30 > data.length) {
    stdout.writeln('--- 没有可解析的 tenc ---');
    return;
  }
  final base = index + 4;
  final version = data[base];
  final isProtected = data[base + 5];
  final ivSize = data[base + 6];
  final kid = data.sublist(base + 7, base + 23);
  stdout.writeln('--- tenc ---');
  stdout.writeln('  version=$version default_isProtected=$isProtected '
      'default_Per_Sample_IV_Size=$ivSize');
  stdout.writeln('  default_KID=${_hex(kid)}');
  if (isProtected == 1 && ivSize == 0) {
    final size = data[base + 23];
    stdout.writeln('  default_constant_IV_size=$size');
    if (size > 0 && base + 24 + size <= data.length) {
      stdout.writeln('  default_constant_IV=${_hex(data.sublist(base + 24, base + 24 + size))}');
    }
  }
}

int _countOccurrences(Uint8List data, String needle) {
  final bytes = needle.codeUnits;
  var count = 0;
  for (var i = 0; i + bytes.length <= data.length; i++) {
    var matched = true;
    for (var j = 0; j < bytes.length; j++) {
      if (data[i + j] != bytes[j]) {
        matched = false;
        break;
      }
    }
    if (matched) count++;
  }
  return count;
}

int _firstOccurrence(Uint8List data, String needle) {
  final bytes = needle.codeUnits;
  for (var i = 0; i + bytes.length <= data.length; i++) {
    var matched = true;
    for (var j = 0; j < bytes.length; j++) {
      if (data[i + j] != bytes[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
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
    final id = dramaFromAny(nestedMap(map, const ['video_data']) ?? map).sourceId;
    if (id.isNotEmpty && !found.contains(id)) found.add(id);
  }
  return found.take(2).toList();
}
