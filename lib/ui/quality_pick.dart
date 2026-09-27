import 'package:hongguo_dart/hongguo_dart.dart';

/// 一档的**有效像素高度**：短边≈红果「P」标签对应的数值。
///
/// 竖屏 1080×1920 → 1080，横屏 1280×720 → 720，与红果「P」标签的语义一致，且天然
/// 纠正被标错的档（有剧把 1280×720 标「1080p」，按短边算得 720，不再被误当 1080）。
///
/// 真实像素缺失（网页 / 备用源的 `width` / `height` 为 0）时退回档位标签 [Media.quality]，
/// 不误判为 0。
int pixelTier(Media media) {
  if (media.width > 0 && media.height > 0) {
    return media.width < media.height ? media.width : media.height;
  }
  return media.quality;
}

/// 按真实像素「就近向上取」在 [variants] 里挑一档，并给出该组最低档 [floor]。
///
/// - 优先挑**不低于** [preferred] 的最小档（向上取，宁可清晰一点也不糊）；
/// - 一档都不低于 [preferred] 时（该剧天花板低于目标），挑最高的那档。
///
/// [floor] 是这一组里最低的有效像素档，供画质面板在 `floor > preferred` 时提示
/// 「该剧最低 NP」——那正是横屏剧只剩 1080 一档、用户设 720 却没变化的场景。
///
/// 调用方需保证 [variants] 非空（空列表由播放页短路，走自动那路）。
({Media pick, int floor}) pickByPreferred(List<Media> variants, int preferred) {
  var floor = pixelTier(variants.first);
  Media? atOrAbove;
  var atOrAboveTier = 1 << 30;
  var highest = variants.first;
  var highestTier = pixelTier(variants.first);

  for (final variant in variants) {
    final tier = pixelTier(variant);
    if (tier < floor) floor = tier;
    if (tier >= preferred && tier < atOrAboveTier) {
      atOrAbove = variant;
      atOrAboveTier = tier;
    }
    if (tier > highestTier) {
      highest = variant;
      highestTier = tier;
    }
  }
  return (pick: atOrAbove ?? highest, floor: floor);
}
