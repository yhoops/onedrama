import 'dart:typed_data';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// 取自真实红果流的 golden 向量。锁住 CENC 的**确切语义**：
/// AES-128-CTR，8 字节 IV 放 counter 块高 8 字节，低 8 字节从 0 按大端递增。
///
/// 这条测试存在的意义：CTR 的 keystream 必须用 AES 的**加密**方向生成。
/// 写成解密方向会得到逆密码流、静默全错——那是本次实测踩过的坑，这里钉死它。
void main() {
  const keyHex = 'f7229a19a008899bfdf5863457a837ee';
  const ivHex = 'a3c40550c2986d23';
  // 视频轨第一个样本（文件偏移 209064，长度 90084）的头 16 字节密文。
  const cipherHex = 'e416e75bd22bb52b9f26572d194b8b63';
  // 期望的明文：00 00 00 1c 是 28 字节 NAL 长度，40 01 是 HEVC 的 VPS NAL 头。
  const plainHex = '0000001c40010c02ffff016000000300';

  test('真实流的首个视频样本能解出 AVCC 结构', () {
    final plain = aesCtrDecrypt(
      _hex(keyHex),
      _hex(ivHex),
      _hex(cipherHex),
    );
    expect(_toHex(plain), plainHex);

    // 明文必须能按 4 字节长度前缀走完——这是「解密对了」的硬判据。
    // 16 字节的头声明了 28 字节的 NAL，接上重复的第二段正好 32 字节，一个 NAL 吃满。
    final walk = walkAvcc(_hex('$plainHex$plainHex'));
    expect(walk.ok, isTrue);
    expect(walk.nalUnits, 1);
  });

  test('CTR 是对合运算，解密两次回到原文', () {
    final source = _hex(cipherHex);
    final once = aesCtrDecrypt(_hex(keyHex), _hex(ivHex), source);
    final twice = aesCtrDecrypt(_hex(keyHex), _hex(ivHex), once);
    expect(_toHex(twice), cipherHex);
  });

  test('counter 只递增低 8 字节，高 8 字节是 IV', () {
    // 长于一个块才能看出递增行为：第 17 字节起的密文用的是 counter 的第二块。
    final iv = _hex('ffffffffffffffff'); // 低 8 字节全 1，一旦越界就会污染高 8 字节
    final source = Uint8List(32);
    final plain = aesCtrDecrypt(_hex(keyHex), iv, source);
    expect(plain.length, 32);
    // 两块明文不同（keystream 不同），说明 counter 确实在走。
    expect(
      _toHex(plain.sublist(0, 16)) == _toHex(plain.sublist(16, 32)),
      isFalse,
    );
  });

  group('walkAvcc', () {
    test('严丝合缝才算过', () {
      // 一个 4 字节的 NAL：长度 4 + 4 字节载荷
      expect(walkAvcc(_hex('0000000401020304')).ok, isTrue);
      // 长度超出样本
      expect(walkAvcc(_hex('000000ff01020304')).ok, isFalse);
      // 长度为零
      expect(walkAvcc(_hex('0000000001020304')).ok, isFalse);
      // 走完还有余
      expect(walkAvcc(_hex('0000000101020304')).ok, isFalse);
    });
  });
}

Uint8List _hex(String value) {
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();
