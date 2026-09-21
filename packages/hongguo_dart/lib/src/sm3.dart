import 'dart:typed_data';

/// SM3 哈希（GB/T 32905-2016）。对照 Go `hongguo/comment_sign.go` 的 `SM3`。
///
/// v1 不做弹幕，这里先把算法落地并锁在 `abc` 固定向量上；等真的接弹幕时
/// `X-Argus` / `X-Ladon` 才有地方站。
Uint8List sm3(List<int> input) {
  final bitLength = input.length * 8;
  final data = <int>[...input, 0x80];
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (var shift = 56; shift >= 0; shift -= 8) {
    data.add((bitLength >> shift) & 0xff);
  }

  final state = <int>[
    0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
  ];
  final words = List<int>.filled(68, 0);

  for (var offset = 0; offset < data.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final base = offset + i * 4;
      words[i] = (data[base] << 24) |
          (data[base + 1] << 16) |
          (data[base + 2] << 8) |
          data[base + 3];
    }
    for (var i = 16; i < 68; i++) {
      final v = (words[i - 16] ^ words[i - 9] ^ _rotl32(words[i - 3], 15)) &
          0xffffffff;
      words[i] = (v ^
              _rotl32(v, 15) ^
              _rotl32(v, 23) ^
              _rotl32(words[i - 13], 7) ^
              words[i - 6]) &
          0xffffffff;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final int t;
      final int ff;
      final int gg;
      if (i < 16) {
        t = 0x79cc4519;
        ff = a ^ b ^ c;
        gg = e ^ f ^ g;
      } else {
        t = 0x7a879d8a;
        ff = (a & b) | (a & c) | (b & c);
        gg = (e & f) | ((~e) & g);
      }
      final ss1 = _rotl32((_rotl32(a, 12) + e + _rotl32(t, i)) & 0xffffffff, 7);
      final tt1 =
          (ff + d + (ss1 ^ _rotl32(a, 12)) + (words[i] ^ words[i + 4])) &
              0xffffffff;
      final tt2 = (gg + h + ss1 + words[i]) & 0xffffffff;

      // Go 的 a, b, c, d = tt1, a, rotl(b,9), c 是同时赋值，必须先把新值算全。
      final newA = tt1;
      final newB = a;
      final newC = _rotl32(b, 9);
      final newD = c;
      final newE = (tt2 ^ _rotl32(tt2, 9) ^ _rotl32(tt2, 17)) & 0xffffffff;
      final newF = e;
      final newG = _rotl32(f, 19);
      final newH = g;
      a = newA;
      b = newB;
      c = newC;
      d = newD;
      e = newE;
      f = newF;
      g = newG;
      h = newH;
    }

    final block = <int>[a, b, c, d, e, f, g, h];
    for (var i = 0; i < 8; i++) {
      state[i] = (state[i] ^ block[i]) & 0xffffffff;
    }
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (state[i] >> 24) & 0xff;
    out[i * 4 + 1] = (state[i] >> 16) & 0xff;
    out[i * 4 + 2] = (state[i] >> 8) & 0xff;
    out[i * 4 + 3] = state[i] & 0xff;
  }
  return out;
}

/// 32 位循环左移。Go 的 `bits.RotateLeft32` 对任意 k 取 k mod 32。
int _rotl32(int value, int count) {
  final v = value & 0xffffffff;
  final n = count & 31;
  if (n == 0) return v;
  return ((v << n) | (v >>> (32 - n))) & 0xffffffff;
}
