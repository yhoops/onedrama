import 'dart:typed_data';

import 'package:dio/dio.dart';

/// ClearKey 的 system id：`1077efec-c0b2-4d02-ace3-3c1e52e2fb4b`。
const List<int> clearKeySystemId = <int>[
  0x10,
  0x77,
  0xef,
  0xec,
  0xc0,
  0xb2,
  0x4d,
  0x02,
  0xac,
  0xe3,
  0x3c,
  0x1e,
  0x52,
  0xe2,
  0xfb,
  0x4b,
];

/// `moov` 里一处可以原地替换的字节区间。
class MoovPatch {
  const MoovPatch({required this.offset, required this.bytes});

  /// 相对文件起点的偏移。
  final int offset;

  /// 替换进去的字节，长度等于被替换掉的盒子。
  final Uint8List bytes;

  String get hex => hexOf(bytes);
}

/// 媒体流 `moov` 里的 CENC 参数。
class CencHeader {
  const CencHeader({
    required this.schemeType,
    required this.keyId,
    required this.perSampleIvSize,
    required this.isProtected,
    this.patch,
  });

  /// `schm` 的保护方案，正常是 `cenc` / `cbcs`。
  final String schemeType;

  /// `tenc` 的 `default_KID`。
  final Uint8List keyId;

  /// `tenc` 的 `default_Per_Sample_IV_Size`。
  final int perSampleIvSize;

  /// `tenc` 的 `default_isProtected`。
  final int isProtected;

  /// 造好的「pssh + free」补丁；`moov` 里没有可换的盒子时为 null。
  final MoovPatch? patch;

  String get keyIdHex => hexOf(keyId);
}

String hexOf(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// 造一段「pssh + free」，用来原地换掉 `moov` 里一个等大的可丢弃盒子。
///
/// 为什么这么做：红果的流没有 `pssh`，ExoPlayer 因此不知道轨道加密、不会建 DRM
/// 会话，会把密文当明文 NAL 解析（`ParserException: Invalid NAL length`，已在真机上
/// 复现）。直接插入 `pssh` 会让 `mdat` 后移，`stco` 的**绝对**偏移全部作废；换成
/// 等大则一个偏移都不用重算。
///
/// [boxSize] 是被替换掉的盒子总长；`pssh` 之外的空间用 `free` 盒子填满，解析器会跳过。
Uint8List buildClearKeyPssh(Uint8List keyId, int boxSize) {
  final psshSize = 8 + 4 + 16 + 4 + keyId.length;
  if (boxSize < psshSize + 8) {
    throw ArgumentError('盒子只有 $boxSize 字节，塞不下 pssh($psshSize) + free');
  }
  final out = Uint8List(boxSize);
  var cursor = 0;
  void u32(int value) {
    out[cursor++] = (value >> 24) & 0xff;
    out[cursor++] = (value >> 16) & 0xff;
    out[cursor++] = (value >> 8) & 0xff;
    out[cursor++] = value & 0xff;
  }

  void ascii(String value) {
    for (final code in value.codeUnits) {
      out[cursor++] = code;
    }
  }

  u32(psshSize);
  ascii('pssh');
  u32(0); // version 0 + flags 0
  out.setRange(cursor, cursor + 16, clearKeySystemId);
  cursor += 16;
  u32(keyId.length);
  out.setRange(cursor, cursor + keyId.length, keyId);
  cursor += keyId.length;

  u32(boxSize - cursor);
  ascii('free');
  return out;
}

/// 从媒体流头部读出 CENC 参数，并算好要替换进去的 `pssh` 补丁。
///
/// 为什么要自己读：ClearKey 许可证里的 `kid` 必须和流里 `tenc` 的 `default_KID`
/// 对上，否则 MediaDrm 找不到对应密钥。而红果的 App 接口只返回密钥，不返回 KID。
///
/// 只请求前 [probeBytes] 字节——`moov` 实测约 210KB，512KB 够用。
Future<CencHeader?> readCencHeader(
  Dio dio,
  String url, {
  String? referer,
  int probeBytes = 512 * 1024,
}) async {
  final response = await dio.get<List<int>>(
    url,
    options: Options(
      headers: {
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
        'Range': 'bytes=0-$probeBytes',
      },
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );
  final data = Uint8List.fromList(response.data ?? const <int>[]);
  if (data.isEmpty) return null;

  final tenc = _find(data, 'tenc');
  if (tenc < 4 || tenc + 4 + 23 > data.length) return null;

  var schemeType = '';
  final schm = _find(data, 'schm');
  if (schm >= 0 && schm + 12 <= data.length) {
    schemeType = String.fromCharCodes(data.sublist(schm + 8, schm + 12));
  }

  final base = tenc + 4;
  final keyId = Uint8List.fromList(data.sublist(base + 7, base + 23));

  // `udta` 是纯元数据，正好够大；换掉它不影响任何偏移。
  final udta = _findMoovChild(data, 'udta');
  MoovPatch? patch;
  if (udta != null) {
    try {
      patch = MoovPatch(
        offset: udta.offset,
        bytes: buildClearKeyPssh(keyId, udta.size),
      );
    } on ArgumentError {
      patch = null;
    }
  }

  return CencHeader(
    schemeType: schemeType,
    keyId: keyId,
    isProtected: data[base + 5],
    perSampleIvSize: data[base + 6],
    patch: patch,
  );
}

/// 在 `moov` 的直接子盒子里找一个指定类型的盒子。
({int offset, int size})? _findMoovChild(Uint8List data, String type) {
  final moovAt = _find(data, 'moov');
  if (moovAt < 4) return null;
  final moovStart = moovAt - 4;
  final moovEnd = moovStart + _readU32(data, moovStart);

  var offset = moovAt + 4;
  while (offset + 8 <= moovEnd && offset + 8 <= data.length) {
    final size = _readU32(data, offset);
    if (size < 8) return null;
    final name = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    if (name == type && offset + size <= data.length) {
      return (offset: offset, size: size);
    }
    offset += size;
  }
  return null;
}

int _readU32(Uint8List data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

/// 找 ASCII 串第一次出现的位置。盒子名就是这样定位的。
int _find(Uint8List data, String needle) {
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
