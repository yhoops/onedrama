import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/player/decrypt_plan.dart';

/// 解密计划的编解码。
///
/// 这条测试存在的意义：真机上出现过「样本偏移读出 0、长度读出十亿」这种错位，而 Java
/// 的 CTR 语义已单独验过没问题——所以错位只可能在编解码这一层。当时编码器把样本记录
/// 里的 IV 漏写了、又在记录后面单独补了一次，每个样本多出 8 字节、后面全部顶歪，
/// 在真机上表现为一个和编解码毫无关系的 `Invalid NAL length`。
///
/// 这里按 **Kotlin 侧那份布局**再解一遍，游标必须严丝合缝走到末尾。
void main() {
  group('encodeDecryptPlan', () {
    final patches = <BytePatch>[
      BytePatch(100, Uint8List.fromList(List<int>.generate(37, (i) => i))),
      BytePatch(
        1000,
        Uint8List.fromList(List<int>.generate(29712, (i) => i % 251)),
      ),
      BytePatch(50000, Uint8List.fromList(<int>[1, 2, 3, 4])),
    ];
    final samples = <CencSample>[
      CencSample(
        offset: 209064,
        size: 90084,
        iv: Uint8List.fromList(
          <int>[0xa3, 0xc4, 0x05, 0x50, 0xc2, 0x98, 0x6d, 0x23],
        ),
      ),
      CencSample(
        offset: 299148,
        size: 29347,
        iv: Uint8List.fromList(
          <int>[0xa3, 0xc4, 0x05, 0x50, 0xc2, 0x98, 0x6d, 0x24],
        ),
      ),
    ];

    test('长度刚好，且按 Kotlin 那份布局能严丝合缝读完', () {
      final encoded = encodeDecryptPlan(
        CencIndex(tracks: const <CencTrack>[], samples: samples),
        patches,
      );

      final expected = 12 + (12 * patches.length + 37 + 29712 + 4) + 20 * samples.length;
      expect(encoded.length, expected, reason: '长度不对就是每个记录多写或少写了字节');

      final buffer = ByteData.sublistView(encoded);
      var cursor = 0;
      int u32() {
        final value = buffer.getUint32(cursor, Endian.little);
        cursor += 4;
        return value;
      }

      int u64() {
        final value = buffer.getUint64(cursor, Endian.little);
        cursor += 8;
        return value;
      }

      expect(u32(), 1, reason: '版本');
      expect(u32(), samples.length, reason: '样本数');
      expect(u32(), patches.length, reason: '补丁数');

      for (var i = 0; i < patches.length; i++) {
        expect(u64(), patches[i].offset, reason: '补丁 #$i 偏移');
        final length = u32();
        expect(length, patches[i].bytes.length, reason: '补丁 #$i 长度');
        expect(
          encoded.sublist(cursor, cursor + length),
          patches[i].bytes,
          reason: '补丁 #$i 内容',
        );
        cursor += length;
      }

      for (var i = 0; i < samples.length; i++) {
        expect(u64(), samples[i].offset, reason: '样本 #$i 偏移');
        expect(u32(), samples[i].size, reason: '样本 #$i 长度');
        expect(
          encoded.sublist(cursor, cursor + 8),
          samples[i].iv,
          reason: '样本 #$i 的 IV 要在记录里，不能是补写的',
        );
        cursor += 8;
      }

      expect(cursor, encoded.length, reason: '游标必须走到末尾——错位就说明字段对不上');
    });

    test('IV 不是 8 字节时直接抛，而不是把错计划发过去', () {
      final bad = CencIndex(
        tracks: const <CencTrack>[],
        samples: <CencSample>[
          CencSample(offset: 0, size: 16, iv: Uint8List(16)),
        ],
      );
      expect(
        () => encodeDecryptPlan(bad, const <BytePatch>[]),
        throwsA(isA<HongguoProtocolException>()),
      );
    });
  });
}
