/// 封面缓存的两层，以及「清除缓存」要清的那一层。
///
/// 封面在**两个**地方各存一份，别只清一个：
///
/// - **磁盘**：`CachedNetworkImage` 不传 `cacheManager` 时用的就是 `DefaultCacheManager`
///   （`cached_network_image_provider.dart`）。它落在临时目录、用 SQLite 记账，默认最多
///   200 个对象、30 天过期（`flutter_cache_manager` 的 `Config`）。
/// - **内存**：Flutter 自己的 `ImageCache`，键是「provider + 解码宽度」。预加载热的就是
///   这一层（见 `ui/cover_prefetch.dart`）。
///
/// 只清磁盘的话，已经在内存里的封面照样显示，用户会以为没清掉。而「清除缓存」在这个 App
/// 里的口径是「可重建的本地副本都清掉」——`settings_page.dart` 里榜单缓存就是按这条加
/// 进去的，封面正好也是可重建副本，没理由例外。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 封面磁盘缓存当前占用。设置页那行「清除缓存」的右侧数字要用它——那个数字得能回答
/// 「按下去会腾出多少」，所以要把封面算进去。
Future<int> coverCacheSize() => DefaultCacheManager().store.getCacheSize();

/// 清掉封面缓存的两层，返回释放的磁盘字节数。
///
/// 内存那层没有便宜的字节统计（`ImageCache` 不报），所以只报磁盘那一份。
Future<int> clearCoverCaches() async {
  final manager = DefaultCacheManager();
  final bytes = await manager.store.getCacheSize();
  await manager.emptyCache();
  // 磁盘之外还得清内存：`emptyCache` 只动磁盘那一层——`ImageCacheManager` 那个 mixin
  // 管的是「缩放派生图」，跟 Flutter 的 ImageCache 是两回事。
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  return bytes;
}
