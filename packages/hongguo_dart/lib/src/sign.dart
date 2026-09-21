import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'bytes.dart';

/// 随机 19 位设备号。对照 Go `hongguo/sign.go` 的 `NewDeviceID`。
///
/// 启动时生成一次后持久化——每次重启都换会让服务端风控更脏。
String newDeviceId() {
  final bytes = Uint8List(8);
  try {
    final random = Random.secure();
    for (var i = 0; i < 8; i++) {
      bytes[i] = random.nextInt(256);
    }
  } on UnsupportedError {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  // Go 用 uint64 读 8 字节，最大值超过 Dart 有符号 64 位整数，必须走 BigInt。
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return (_deviceBase + (value % _deviceSpan)).toString();
}

/// 设备号取值区间：`1e18 + rand % 8e18`，与 Go 的常量一致。
final BigInt _deviceBase = BigInt.parse('1000000000000000000');
final BigInt _deviceSpan = BigInt.parse('8000000000000000000');

/// `X-Gorgon` 的混淆密钥。对照 Go `hongguo/sign.go`。
const List<int> _gorgonKey = <int>[
  0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93,
  0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f,
];

/// 生成普通 App 请求的签名头。
///
/// 对照 Go `hongguo/sign.go` 的 `SignRequest`——那里就地改 `*http.Request`，
/// 这里返回头表由网络层挂上去。[body] 传 null 时不产生 `X-SS-STUB`，与 Go 一致。
///
/// [rawQuery] 必须是最终要发的查询串（含后端追加的 `_rticket`），签名算的就是它。
Map<String, String> signRequest({
  required String rawQuery,
  List<int>? body,
  required DateTime now,
}) {
  final timestamp = (now.millisecondsSinceEpoch ~/ 1000) & 0xffffffff;
  final payload = Uint8List(20);

  final queryHash = crypto.md5.convert(utf8.encode(rawQuery)).bytes;
  payload.setRange(0, 4, queryHash.sublist(0, 4));

  String? stub;
  if (body != null) {
    final bodyHash = crypto.md5.convert(body).bytes;
    payload.setRange(4, 8, bodyHash.sublist(0, 4));
    // Go 是 fmt.Sprintf("%X")，大写；X-Gorgon 走 hex.EncodeToString，小写。
    stub = hexEncode(bodyHash).toUpperCase();
  }

  payload.setRange(12, 16, const <int>[0, 6, 11, 28]);
  payload[16] = (timestamp >> 24) & 0xff;
  payload[17] = (timestamp >> 16) & 0xff;
  payload[18] = (timestamp >> 8) & 0xff;
  payload[19] = timestamp & 0xff;

  for (var i = 0; i < 20; i++) {
    payload[i] ^= _gorgonKey[i];
  }
  // 这个循环就地读同一下标的下一个字节，最后一个会读到本轮已改过的 payload[0]，
  // 与 Go 行为一致，不能改成读副本。
  for (var i = 0; i < 20; i++) {
    final mixed = rotl8(payload[i], 4) ^ payload[(i + 1) % 20];
    payload[i] = (reverse8(mixed) ^ 0xff ^ 20) & 0xff;
  }

  final headers = <String, String>{
    'X-Khronos': timestamp.toString(),
    'X-Gorgon': hexEncode(<int>[0x84, 0x04, 0x40, 0x1c, 0, 0, ...payload]),
    'X-SS-Req-Ticket': now.millisecondsSinceEpoch.toString(),
  };
  if (stub != null) {
    headers['X-SS-STUB'] = stub;
  }
  return headers;
}
