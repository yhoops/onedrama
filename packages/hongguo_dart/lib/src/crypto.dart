import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bytes.dart';

/// 协议层错误。对应 Go 里那些 `errors.New` / `fmt.Errorf`。
class HongguoProtocolException implements Exception {
  HongguoProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解码 base64。
///
/// Go 先试 `base64.StdEncoding.Strict()`，失败再试 `RawStdEncoding.Strict()`。
/// Dart 的 `base64.decode` 会自动补 padding，等价于依次试这两者；差别是 Dart
/// 不校验尾部多余比特（Go 的 `Strict()` 会拒绝），实际载荷里遇不到。
Uint8List? decodeBase64(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  try {
    return base64.decode(text);
  } on FormatException {
    return null;
  }
}

/// 去 PKCS#7 填充。
Uint8List pkcs7Unpad(Uint8List source, int blockSize) {
  if (source.isEmpty || source.length % blockSize != 0) {
    throw HongguoProtocolException('invalid pkcs7 length');
  }
  final pad = source[source.length - 1];
  if (pad == 0 || pad > blockSize || pad > source.length) {
    throw HongguoProtocolException('invalid pkcs7 padding');
  }
  for (var i = source.length - pad; i < source.length; i++) {
    if (source[i] != pad) {
      throw HongguoProtocolException('invalid pkcs7 padding bytes');
    }
  }
  return Uint8List.sublistView(source, 0, source.length - pad);
}

/// 从 `spade_a` 还原 AES-128 CENC 密钥。拒绝 `app_v2` / `web_v2`。
///
/// 对照 Go `hongguo/crypto.go` 的 `ContentKey`。拿到密钥后由播放器做
/// CENC/AES-CTR 解密，本包不解封装。
Uint8List contentKey(String value) {
  if (value.length > 1024) {
    throw HongguoProtocolException('红果媒体密钥数据过长');
  }
  final raw = decodeBase64(value);
  if (raw == null || raw.length < 3) {
    throw HongguoProtocolException('红果媒体密钥编码无效');
  }

  final tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
  final contentLength = raw.length - tagLength - 1;
  if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
    throw HongguoProtocolException('红果媒体密钥结构无效');
  }

  final seed =
      raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
  final tag = String.fromCharCodes(
    List<int>.generate(
      tagLength,
      (i) => raw[raw.length - tagLength + i] ^ seed,
    ),
  );
  if (tag == 'app_v2' || tag == 'web_v2') {
    throw HongguoProtocolException('红果媒体密钥版本暂不支持');
  }

  final decoded = Uint8List(contentLength);
  var previousEven = 250;
  var previousOdd = 85;
  for (var index = 0; index < contentLength; index++) {
    final current = raw[1 + index];
    final int previous;
    if (index.isEven) {
      previous = previousEven;
      previousEven = current;
    } else {
      previous = previousOdd;
      previousOdd = current;
    }
    decoded[index] = ((previous ^ current) - 21 - popCount(index)) & 0xff;
  }

  // 首字节是 base36 的填充长度；Go 用 ParseUint(.., 36, 8)，只吃 0-9 a-z A-Z。
  final padCode = decoded[0];
  final isBase36 = (padCode >= 0x30 && padCode <= 0x39) ||
      (padCode >= 0x61 && padCode <= 0x7a) ||
      (padCode >= 0x41 && padCode <= 0x5a);
  if (!isBase36) {
    throw HongguoProtocolException('红果媒体密钥内容无效');
  }
  final padding = int.parse(String.fromCharCode(padCode), radix: 36);
  if (contentLength - padding - 1 != 32) {
    throw HongguoProtocolException('红果媒体密钥内容无效');
  }

  final key = hexDecode(String.fromCharCodes(decoded.sublist(1, 33)));
  if (key == null || key.length != 16) {
    throw HongguoProtocolException('红果媒体密钥不是有效的 AES-128 密钥');
  }
  return key;
}

/// 备用播放接口响应的密钥材料长度：16 字节 AES 密钥 + 16 字节 IV。
const int _materialBytes = 32;

/// 密钥材料的混淆表。对照 Go `hongguo/crypto.go`。
const List<int> _materialMask = <int>[
  104, 64, 70, 166, 190, 168, 143, 130, 225, 254,
  251, 217, 196, 34, 45, 60, 29, 20, 103, 105,
];

/// 解密备用播放接口响应。明文 JSON 原样返回；`v2.{hex密钥}.{密文}` 走
/// AES-CBC + PKCS7。
///
/// 对照 Go `hongguo/crypto.go` 的 `DecodePlaybackResponse`。
Uint8List decodePlaybackResponse(String body) {
  final text = body.trim();
  if (!text.startsWith('v2.')) {
    return Uint8List.fromList(utf8.encode(text));
  }

  // Go 是 SplitN(text, ".", 3)：第二段是密钥，第三段是密文，密文里可以有点号。
  final firstDot = text.indexOf('.');
  final secondDot = text.indexOf('.', firstDot + 1);
  if (secondDot < 0) {
    throw HongguoProtocolException('红果备用接口响应密钥无效');
  }
  final encodedPart = text.substring(firstDot + 1, secondDot);
  final cipherPart = text.substring(secondDot + 1);

  if (encodedPart.length <= 4 || encodedPart.length > 1028) {
    throw HongguoProtocolException('红果备用接口响应密钥无效');
  }
  final encoded = hexDecode(encodedPart.substring(4));
  if (encoded == null || encoded.length < _materialBytes) {
    throw HongguoProtocolException('红果备用接口响应密钥无效');
  }

  final material = Uint8List(encoded.length);
  for (var index = 0; index < encoded.length; index++) {
    final current = encoded[index];
    final previous = index > 0 ? encoded[index - 1] : 109;
    final slot = index % _materialMask.length;
    final salt = _materialMask[slot] ^ ((90 + 13 * slot) & 0xff) ^ 85;
    final shifted = (current + 215 - 11 * index) & 0xff;
    material[index] = previous ^ salt ^ rotl8(shifted, 3);
  }

  final ciphertext = decodeBase64(cipherPart);
  if (ciphertext == null || ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    throw HongguoProtocolException('红果备用接口加密响应无效');
  }

  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(material.sublist(0, 16)),
        material.sublist(16, 32),
      ),
    );
  final plain = Uint8List(ciphertext.length);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    cipher.processBlock(ciphertext, offset, plain, offset);
  }
  return pkcs7Unpad(plain, 16);
}
