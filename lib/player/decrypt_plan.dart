import 'dart:typed_data';

import 'package:hongguo_dart/hongguo_dart.dart';

/// 把样本索引与等长替换补丁编成 Kotlin 侧认得的二进制。
///
/// 布局（小端，对应 `CencDecryptDataSource.kt` 里的 `DecryptPlan`）：
///
/// ```
/// u32 版本 = 1
/// u32 样本数
/// u32 补丁数
/// 补丁 × N：u64 偏移, u32 长度, 字节
/// 样本 × N：u64 偏移, u32 长度, 8 字节 IV
/// ```
///
/// **为什么传过去而不是让 Kotlin 自己解 `moov`**：协议知识留在 Dart——那边有 Go 包做
/// 对照、有 fixtures 比对（ADR-0003），Kotlin 只做「照单子解密」这种机械活。
/// 一次约 180 KB，一集只传一次。
Uint8List encodeDecryptPlan(CencIndex index, List<BytePatch> patches) {
  for (final sample in index.samples) {
    // 到目前见到的流都是 8 字节 IV。真遇上 16 字节的，宁可在这里炸掉，也别把一份
    // 格式不对的计划丢过去让播放器静默解出乱码。
    if (sample.iv.length != 8) {
      throw HongguoProtocolException(
        '只支持 8 字节 IV 的流，这一条是 ${sample.iv.length} 字节',
      );
    }
  }

  final out = BytesBuilder(copy: false);

  final header = ByteData(12)
    ..setUint32(0, 1, Endian.little)
    ..setUint32(4, index.samples.length, Endian.little)
    ..setUint32(8, patches.length, Endian.little);
  out.add(header.buffer.asUint8List());

  for (final patch in patches) {
    final record = ByteData(12)
      ..setUint64(0, patch.offset, Endian.little)
      ..setUint32(8, patch.bytes.length, Endian.little);
    out.add(record.buffer.asUint8List());
    out.add(patch.bytes);
  }

  for (final sample in index.samples) {
    // 样本记录就是 20 字节：偏移 8 + 长度 4 + IV 8。**IV 要写进记录里**，
    // 别再单独 add 一次——那会每个样本多出 8 字节，把后面全部顶歪（踩过）。
    final record = Uint8List(20);
    final view = ByteData.sublistView(record);
    view.setUint64(0, sample.offset, Endian.little);
    view.setUint32(8, sample.size, Endian.little);
    record.setRange(12, 20, sample.iv);
    out.add(record);
  }

  return out.toBytes();
}
