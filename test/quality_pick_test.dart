import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/ui/quality_pick.dart';

/// 一档竖屏媒体：短边=tier（720 档就是 720×1280）。
Media portrait(int tier, {int? label}) => Media(
  url: 'https://x/$tier',
  referer: 'https://x',
  quality: label ?? tier,
  width: tier,
  height: tier * 16 ~/ 9,
);

void main() {
  group('pixelTier：按短边算，不信标签', () {
    test('竖屏取宽（短边）', () {
      expect(pixelTier(portrait(1080)), 1080);
      expect(pixelTier(portrait(720)), 720);
    });

    test('横屏取高（短边）', () {
      final landscape = Media(
        url: 'https://x',
        referer: 'https://x',
        quality: 1080, // 被标成 1080p
        width: 1280,
        height: 720,
      );
      expect(pixelTier(landscape), 720); // 纠正标错：短边 720
    });

    test('真实像素缺失时退回档位标签', () {
      final web = Media(url: 'https://x', referer: 'https://x', quality: 720);
      expect(pixelTier(web), 720);
      final blank = Media(url: 'https://x', referer: 'https://x');
      expect(pixelTier(blank), 0);
    });
  });

  group('pickByPreferred：就近向上取', () {
    test('有不低于目标的档 → 取其中最小（向上）', () {
      final r = pickByPreferred([portrait(480), portrait(1080)], 720);
      expect(pixelTier(r.pick), 1080);
      expect(r.floor, 480);
    });

    test('恰好命中目标 → 取该档', () {
      final r = pickByPreferred(
        [portrait(480), portrait(720), portrait(1080)],
        720,
      );
      expect(pixelTier(r.pick), 720);
      expect(r.floor, 480);
    });

    test('一档都不低于目标（该剧只剩更低档）→ 取最高档', () {
      final r = pickByPreferred([portrait(480), portrait(720)], 1080);
      expect(pixelTier(r.pick), 720);
      expect(r.floor, 480);
    });

    test('横屏剧只剩 1080：设 720 落到 1080，floor 高于目标可提示', () {
      final r = pickByPreferred([portrait(1080)], 720);
      expect(pixelTier(r.pick), 1080);
      expect(r.floor, 1080);
      expect(r.floor > 720, isTrue); // 面板据此显示「该剧最低 1080P」
    });
  });
}
