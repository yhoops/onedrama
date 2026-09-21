import 'dart:typed_data';

/// 字节级位运算工具。对照 Go 的 `math/bits`。

/// 8 位循环左移。
int rotl8(int value, int count) {
  final v = value & 0xff;
  final n = count & 7;
  if (n == 0) return v;
  return ((v << n) | (v >>> (8 - n))) & 0xff;
}

/// 8 位按位反转。对照 `bits.Reverse8`。
int reverse8(int value) {
  var v = value & 0xff;
  var out = 0;
  for (var i = 0; i < 8; i++) {
    out = (out << 1) | (v & 1);
    v >>= 1;
  }
  return out;
}

/// 二进制中 1 的个数。对照 `bits.OnesCount`。
int popCount(int value) {
  var v = value;
  var count = 0;
  while (v != 0) {
    count += v & 1;
    v >>= 1;
  }
  return count;
}

/// 解码十六进制；非法输入或奇数长度返回 null。对照 `hex.DecodeString`。
Uint8List? hexDecode(String value) {
  if (value.length.isOdd) return null;
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final high = _hexDigit(value.codeUnitAt(i * 2));
    final low = _hexDigit(value.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) return null;
    out[i] = (high << 4) | low;
  }
  return out;
}

/// 编码为小写十六进制。对照 `hex.EncodeToString`。
String hexEncode(List<int> value) {
  final buffer = StringBuffer();
  for (final byte in value) {
    buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

int _hexDigit(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return -1;
}
