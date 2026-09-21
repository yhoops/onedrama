import 'dart:convert';
import 'dart:io';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// 契约测试：向量由 Go 侧生成，Go 包是协议真相。
///
/// 重新生成向量：
///   cd hongguo && EMIT_VECTORS=1 go test -run TestEmitVectors .
///
/// 这份测试红了就说明 Dart 移植和 Go 分叉了——这正是它存在的意义。
Map<String, dynamic> _loadVectors() {
  // dart test 的工作目录是包根（packages/hongguo_dart），上两级是仓库根。
  final fixture =
      File('${Directory.current.parent.parent.path}/hongguo/testdata/vectors.json');
  if (!fixture.existsSync()) {
    throw StateError('缺少向量文件 ${fixture.path}；先在 hongguo/ 里生成它。');
  }
  return jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();

void main() {
  final vectors = _loadVectors();

  group('sm3', () {
    for (final row in vectors['sm3'] as List) {
      final c = row as Map<String, dynamic>;
      test('sm3(${jsonEncode(c['input'])})', () {
        expect(_hex(sm3(utf8.encode(c['input'] as String))), c['hex']);
      });
    }
  });

  group('splitDramaId', () {
    for (final row in vectors['splitDramaId'] as List) {
      final c = row as Map<String, dynamic>;
      test(jsonEncode(c['identifier']), () {
        final got = splitDramaId(c['identifier'] as String);
        if (c['ok'] as bool) {
          expect(got, c['sourceId']);
        } else {
          expect(got, isNull);
        }
      });
    }
  });

  group('signRequest', () {
    for (final row in vectors['signRequest'] as List) {
      final c = row as Map<String, dynamic>;
      test(c['name'] as String, () {
        final headers = signRequest(
          rawQuery: c['rawQuery'] as String,
          body: (c['hasBody'] as bool) ? utf8.encode(c['body'] as String) : null,
          now: DateTime.fromMillisecondsSinceEpoch(
            (c['unix'] as int) * 1000,
            isUtc: true,
          ),
        );
        expect(headers, Map<String, String>.from(c['headers'] as Map));
      });
    }

    test('没有 body 时不产生 X-SS-STUB', () {
      final headers = signRequest(
        rawQuery: 'aid=8662',
        now: DateTime.fromMillisecondsSinceEpoch(1773662280000, isUtc: true),
      );
      expect(headers.containsKey('X-SS-STUB'), isFalse);
    });
  });

  group('contentKey', () {
    for (final row in vectors['contentKey'] as List) {
      final c = row as Map<String, dynamic>;
      test(c['name'] as String, () {
        final spade = c['spade'] as String;
        final error = c['error'] as String;
        if (error.isEmpty) {
          expect(_hex(contentKey(spade)), c['key']);
        } else {
          expect(
            () => contentKey(spade),
            throwsA(
              isA<HongguoProtocolException>()
                  .having((e) => e.message, 'message', error),
            ),
          );
        }
      });
    }

    test('拒绝超长输入', () {
      expect(
        () => contentKey('a' * 1025),
        throwsA(isA<HongguoProtocolException>()),
      );
    });

    test('拒绝非法 base64', () {
      expect(
        () => contentKey('!!! not base64 !!!'),
        throwsA(isA<HongguoProtocolException>()),
      );
    });
  });

  group('decodePlaybackResponse', () {
    for (final row in vectors['decodePlaybackResponse'] as List) {
      final c = row as Map<String, dynamic>;
      test(c['name'] as String, () {
        expect(utf8.decode(decodePlaybackResponse(c['body'] as String)),
            c['plain']);
      });
    }

    test('v2 缺少第二段时拒绝', () {
      expect(
        () => decodePlaybackResponse('v2.onlyonepart'),
        throwsA(isA<HongguoProtocolException>()),
      );
    });
  });

  group('ID 工具', () {
    test('dramaId / episodeId', () {
      expect(dramaId('753216'), 'hongguo:753216');
      expect(episodeId('753216', '748001'), 'hongguo:753216:748001');
    });

    test('占位地址往返', () {
      expect(mediaPlaceholder('748001'), 'hongguo-cenc://748001');
      expect(videoIdFromUrl('hongguo-cenc://748001'), '748001');
      expect(videoIdFromUrl('748001'), '748001');
    });

    test('canonicalSource 认站点域名', () {
      expect(canonicalSource('hongguo'), 'hongguo');
      expect(canonicalSource('www.hongguoduanju.com'), 'hongguo');
      expect(canonicalSource('other'), '');
    });

    test('numericIdPattern 限 1–32 位数字', () {
      expect(numericIdPattern.hasMatch('1'), isTrue);
      expect(numericIdPattern.hasMatch('1' * 32), isTrue);
      expect(numericIdPattern.hasMatch('1' * 33), isFalse);
      expect(numericIdPattern.hasMatch(''), isFalse);
      expect(numericIdPattern.hasMatch('12a'), isFalse);
    });
  });

  group('newDeviceId', () {
    test('是 19 位数字，且两次不同', () {
      final first = newDeviceId();
      final second = newDeviceId();
      expect(RegExp(r'^[0-9]{19}$').hasMatch(first), isTrue, reason: first);
      expect(first == second, isFalse);
    });
  });
}
