/// 封面缓存的两层，以及「清除缓存」要清的那一层。
///
/// 封面在**两个**地方各存一份，别只清一个：
///
/// - **磁盘**：[CoverCacheManager]，落在临时目录、用 SQLite 记账，最多
///   [maxCachedCovers] 个对象、30 天过期。
/// - **内存**：Flutter 自己的 `ImageCache`，键是「provider + 解码宽度」。预加载热的就是
///   这一层（见 `ui/cover_prefetch.dart`）。
///
/// 只清磁盘的话，已经在内存里的封面照样显示，用户会以为没清掉。而「清除缓存」在这个 App
/// 里的口径是「可重建的本地副本都清掉」——`settings_page.dart` 里榜单缓存就是按这条加
/// 进去的，封面正好也是可重建副本，没理由例外。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 封面磁盘缓存能留几个对象。
///
/// **要盖过一次导入热的总数**：四个标签 × 5 页 × 18 部 = 360（见 `docs/adr/0008`）。
/// `DefaultCacheManager` 的默认值是 200（`flutter_cache_manager` 的 `Config`），也就
/// 是说导入器刚热完就有约 160 张被 LRU 挤掉、白热——而它是并发 4 路热的，谁被挤掉
/// 完全看运气。360 张 × 约 24 KB ≈ 8.6 MB，提到 400 的磁盘代价可以忽略。
const int maxCachedCovers = 400;

/// 封面磁盘缓存。**四处必须共用这一个实例**：`DramaCover`、`CoverPrefetcher`、
/// `openDrama` 里的 `precacheImage`、以及导入器的预热。各开各的话，预热热的是这份、
/// UI 读的是那份，「热了却还要等」。
///
/// 自定义 `CacheManager` 只为一件事：对象数上限（见 [maxCachedCovers]）。`stalePeriod`
/// 保持默认的 30 天，与 `DefaultCacheManager` 一致。
///
/// 注意 `cacheKey` 同时是磁盘上那份 SQLite 账本的文件名——**换它等于换一份缓存**，
/// 老的那份会变成没人管的孤儿文件（见 [_legacyCoverCache]）。
class CoverCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'onedramaCoverCache';

  static final CoverCacheManager _instance = CoverCacheManager._();

  factory CoverCacheManager() => _instance;

  CoverCacheManager._()
    : super(Config(key, maxNrOfCacheObjects: maxCachedCovers));
}

/// 上一版用的缓存（`DefaultCacheManager`，键 `libCachedImageData`）。换了上面那个
/// `cacheKey` 之后它成了孤儿：新 manager 读不到它，而「清除缓存」既不报它也不清它。
///
/// 所以尺寸与清理都把它算进来，别让它一直躺在缓存目录里。等没有装着改版之前那个包的
/// 设备了，本文件里与它相关的三处（这个 getter、[coverCacheSize]、[clearCoverCaches]）
/// 一起删掉即可。
///
/// 类型写成 `DefaultCacheManager` 而不是 `BaseCacheManager`：只有前者有 `store`。
DefaultCacheManager get _legacyCoverCache => DefaultCacheManager();

/// 封面磁盘缓存当前占用。设置页那行「清除缓存」的右侧数字要用它——那个数字得能回答
/// 「按下去会腾出多少」，所以要把封面算进去（含上面那份孤儿，它确实会被腾出来）。
Future<int> coverCacheSize() async {
  final current = await CoverCacheManager().store.getCacheSize();
  return current + await _legacyCoverCache.store.getCacheSize();
}

/// 清掉封面缓存的两层，返回释放的磁盘字节数。
///
/// 内存那层没有便宜的字节统计（`ImageCache` 不报），所以只报磁盘那一份。
Future<int> clearCoverCaches() async {
  final manager = CoverCacheManager();
  var bytes = await manager.store.getCacheSize();
  await manager.emptyCache();
  // 顺手把改版前那份孤儿也腾掉，否则它会一直躺在缓存目录里。
  bytes += await _legacyCoverCache.store.getCacheSize();
  await _legacyCoverCache.emptyCache();
  // 磁盘之外还得清内存：`emptyCache` 只动磁盘那一层——`ImageCacheManager` 那个 mixin
  // 管的是「缩放派生图」，跟 Flutter 的 ImageCache 是两回事。
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  return bytes;
}
