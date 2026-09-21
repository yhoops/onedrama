import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/media_cache.dart';

/// 剧集缓存的命名与淘汰规则。
///
/// 这些函数都带一个可注入的 [Directory]——`path_provider` 在单测里没有平台通道，
/// 真机上才能拿到临时目录。规则本身是纯文件操作，值得在这儿钉住：命名一旦分叉，
/// 「清除缓存」就会漏，而漏掉的东西在真机上表现为「明明清了还占着几百 MB」。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('onedrama-cache-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> seed(String name, {int bytes = 2048, DateTime? at}) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(Uint8List(bytes));
    if (at != null) await file.setLastModified(at);
    return file;
  }

  Future<bool> exists(String name) => File('${dir.path}/$name').exists();

  group('清除缓存', () {
    test('连旁挂与半截的 .part 一起清，但集数只数 .mp4', () async {
      await seed('cenc_a.mp4');
      await seed('cenc_a.json', bytes: 256);
      await seed('cenc_b.mp4.part', bytes: 512);
      await seed('cenc_b.json.part', bytes: 128);
      await seed('unrelated.txt', bytes: 64);

      final result = await clearEpisodeCache(directory: dir);

      expect(result.files, 1, reason: '只有 cenc_a.mp4 算一集');
      expect(result.bytes, 2048 + 256 + 512 + 128);
      expect(await exists('cenc_a.mp4'), isFalse);
      expect(await exists('cenc_a.json'), isFalse);
      expect(await exists('cenc_b.mp4.part'), isFalse);
      expect(await exists('cenc_b.json.part'), isFalse);
      // 不是我们的文件一个都不动。
      expect(await exists('unrelated.txt'), isTrue);
    });

    test('目录里什么都没有时不报错', () async {
      final result = await clearEpisodeCache(directory: dir);
      expect(result.files, 0);
      expect(result.bytes, 0);
    });
  });

  group('缓存占用', () {
    test('集数只数 .mp4，字节数含旁挂与 .part', () async {
      await seed('cenc_a.mp4');
      await seed('cenc_b.mp4');
      await seed('cenc_a.json', bytes: 256);
      await seed('cenc_b.mp4.part', bytes: 512);

      final usage = await episodeCacheUsage(directory: dir);

      expect(usage.files, 2);
      expect(usage.bytes, 2048 * 2 + 256 + 512);
    });
  });

  group('淘汰', () {
    test('按文件时间留最近 N 集，连旁挂一起删', () async {
      final base = DateTime(2026, 9, 21, 12);
      await seed('cenc_new.mp4', at: base);
      await seed('cenc_new.json', bytes: 64, at: base);
      await seed('cenc_mid.mp4', at: base.subtract(const Duration(minutes: 1)));
      await seed('cenc_mid.json', bytes: 64,
          at: base.subtract(const Duration(minutes: 1)));
      await seed('cenc_old.mp4', at: base.subtract(const Duration(minutes: 2)));
      await seed('cenc_old.json', bytes: 64,
          at: base.subtract(const Duration(minutes: 2)));

      final removed = await pruneEpisodeCache(directory: dir, keep: 2);

      expect(removed, 1);
      expect(await exists('cenc_new.mp4'), isTrue);
      expect(await exists('cenc_mid.mp4'), isTrue);
      expect(await exists('cenc_old.mp4'), isFalse);
      // 旁挂跟着走，不留孤儿。
      expect(await exists('cenc_old.json'), isFalse);
      expect(await exists('cenc_new.json'), isTrue);
    });

    test('protect 里的集永不淘汰，哪怕它最旧', () async {
      final base = DateTime(2026, 9, 21, 12);
      await seed('cenc_playing.mp4', at: base.subtract(const Duration(hours: 1)));
      await seed('cenc_new.mp4', at: base);
      await seed('cenc_mid.mp4', at: base.subtract(const Duration(minutes: 1)));

      final removed = await pruneEpisodeCache(
        directory: dir,
        keep: 1,
        protect: const {'playing'},
      );

      // 最旧的 playing 被保护，退而求其次淘汰 mid。
      expect(removed, 1);
      expect(await exists('cenc_playing.mp4'), isTrue);
      expect(await exists('cenc_new.mp4'), isTrue);
      expect(await exists('cenc_mid.mp4'), isFalse);
    });

    test('清掉没有剧集文件的孤儿旁挂，但不碰 .part', () async {
      await seed('cenc_alive.mp4');
      await seed('cenc_alive.json', bytes: 64);
      await seed('cenc_orphan.json', bytes: 64);
      await seed('cenc_downloading.mp4.part', bytes: 512);

      await pruneEpisodeCache(directory: dir, keep: 10);

      expect(await exists('cenc_orphan.json'), isFalse);
      expect(await exists('cenc_alive.json'), isTrue);
      // 正在下的那份删了会让下载以奇怪的方式失败，绝不能碰。
      expect(await exists('cenc_downloading.mp4.part'), isTrue);
    });

    test('没到上限时一个都不删', () async {
      for (final name in ['a', 'b', 'c']) {
        await seed('cenc_$name.mp4');
      }
      expect(await pruneEpisodeCache(directory: dir, keep: 10), 0);
      expect(await exists('cenc_a.mp4'), isTrue);
    });
  });

  group('旁挂往返', () {
    Uint8List key(int seed) =>
        Uint8List.fromList(List<int>.generate(16, (i) => (i + seed) & 0xff));

    test('写进去的那一档能读回来，且带着完整档位列表', () async {
      // 形状照 `selectAppMedia` 的真实产出：**每个档位都带 duration**（它是从同一个
      // model 上读出来发给每一路的），不是只有外层才有。
      const duration = Duration(seconds: 121);
      final outer = Media(
        url: 'https://example.com/1080.mp4',
        referer: 'https://example.com/',
        duration: duration,
        cencKey: key(1),
        quality: 1080,
        width: 1080,
        height: 1920,
        variants: [
          Media(
            url: 'https://example.com/1080.mp4',
            referer: 'https://example.com/',
            duration: duration,
            quality: 1080,
            width: 1080,
            height: 1920,
            cencKey: key(1),
          ),
          Media(
            url: 'https://example.com/720.mp4',
            referer: 'https://example.com/',
            duration: duration,
            quality: 720,
            width: 720,
            height: 1280,
            cencKey: key(2),
          ),
        ],
      );

      await writeEpisodeSidecar(
        'vid',
        media: outer,
        pickedQuality: 720,
        directory: dir,
      );
      final restored = await readEpisodeSidecar('vid', directory: dir);

      expect(restored, isNotNull);
      // 磁盘上是 720 那一档——读回来必须还是它，而不是「按设置重挑一次」的结果。
      expect(restored!.quality, 720);
      expect(restored.url, 'https://example.com/720.mp4');
      expect(restored.width, 720);
      expect(restored.cencKey, key(2));
      expect(restored.duration, const Duration(seconds: 121));
      // 外层与档位是同一批，按 URL 去重后是 2 条而不是 3 条。
      expect(
        restored.variants.map((media) => media.url).toSet(),
        {'https://example.com/1080.mp4', 'https://example.com/720.mp4'},
      );
    });

    test('明文流（没有密钥）也往返得回来', () async {
      await writeEpisodeSidecar(
        'vid',
        media: const Media(
          url: 'https://example.com/plain.mp4',
          referer: 'https://example.com/',
          quality: 480,
        ),
        pickedQuality: 480,
        directory: dir,
      );
      final restored = await readEpisodeSidecar('vid', directory: dir);
      expect(restored, isNotNull);
      expect(restored!.cencKey, isNull);
      expect(restored.quality, 480);
    });

    test('没有旁挂、或旁挂坏了，都返回 null 让调用方走网络', () async {
      expect(await readEpisodeSidecar('missing', directory: dir), isNull);

      await File('${dir.path}/cenc_broken.json').writeAsString('{ 这不是 JSON');
      expect(await readEpisodeSidecar('broken', directory: dir), isNull);

      await File('${dir.path}/cenc_empty.json').writeAsString('{"variants":[]}');
      expect(await readEpisodeSidecar('empty', directory: dir), isNull);
    });
  });
}
