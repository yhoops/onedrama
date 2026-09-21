import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// 封面预取：把「马上要滑到」的那一屏封面提前解码进 Flutter 的内存 `ImageCache`。
///
/// **为什么必须热到内存，而不是只热磁盘**：`CachedNetworkImage` 底下的 `octo_image`
/// 在图片「同步可得」时走 `wasSynchronouslyLoaded` 分支，直接出图、**连占位与淡入都不放**
/// （`octo_image-2.1.0/lib/src/image/image_handler.dart` 的 `_placeholderBuilder`）。
/// 磁盘命中仍然是异步读盘 + 解码，仍然会看到灰底占位 + `DramaCover` 那 220ms 淡入
/// ——所以 `downloadFile` 那类只落盘的预热解决不了这件事。
///
/// **缓存键必须和组件一模一样，否则白热**：组件实际交出去的是
/// `ResizeImage.resizeIfNeeded(memCacheWidth, null, CachedNetworkImageProvider(url))`
/// （`octo_image/lib/src/image/image.dart`），等价于 `ResizeImage(provider, width: w)`、
/// policy 与 allowUpscaling 取默认（`painting/image_provider.dart` 的 `resizeIfNeeded`）。
/// 缓存键 = provider + policy + width + height + allowUpscaling，而
/// `CachedNetworkImageProvider.obtainKey` 直接返回自己、`ImageConfiguration` 不参与，
/// 所以照抄同一个构造就能命中。
///
/// **窗口永远取前缘之后的一段**：往回滑不会重排已经热过的（地址级去重），所以实际效果
/// 是「补上先前甩动太快跳过的那些」，不会去动你早看过、还在内存里的那几张。
class CoverPrefetcher {
  CoverPrefetcher({
    required this.memCacheWidth,
    this.window = defaultWindow,
    this.concurrent = defaultConcurrent,
  });

  /// 一次最多热几张，约一屏半：2 列网格一屏 4 张、榜单列表一屏约 10 行。
  ///
  /// 别贪多：每张在内存里约 0.33–1.32 MB（看 [memCacheWidth]），热太多会把**当前正显示
  /// 的**那些挤出 `ImageCache`——那就从「省一次加载」变成「多一次加载」了。
  static const int defaultWindow = 12;

  /// 同时在飞的请求数。堆太多会在几帧里塞满解码任务，反而把滚动卡住。
  static const int defaultConcurrent = 3;

  /// 解码宽度。**必须与同一处封面的 `DramaCover.memCacheWidth` 相等**，否则缓存键不同。
  final int memCacheWidth;

  final int window;
  final int concurrent;

  /// 已经排过队的地址。不是「已经加载成功」——失败的也留在里面，免得反复重排。
  final Set<String> _enqueued = <String>{};
  final List<String> _queue = <String>[];
  int _inFlight = 0;
  bool _drainScheduled = false;
  bool _disposed = false;

  /// 列表把「当前构建到第几条」报进来（在 `itemBuilder` 里调）。
  ///
  /// 不去算滚动偏移：`SliverChildBuilderDelegate` 只构建可见区那几条，所以「已构建到的
  /// 最大下标」就是**前缘**。窗口于是自动跟着滚动走，而且不必知道网格几何——2 列网格与
  /// 单列列表共用这一份实现。
  ///
  /// [urlAt] 把下标映射成封面地址；越界返回空串即可（会被跳过）。
  void advanceTo(int lastBuiltIndex, String Function(int index) urlAt) {
    if (_disposed) return;

    for (
      var index = lastBuiltIndex + 1;
      index <= lastBuiltIndex + window;
      index++
    ) {
      final url = urlAt(index);
      if (url.isEmpty) continue;
      if (_enqueued.add(url)) _queue.add(url);
    }

    if (_drainScheduled || _queue.isEmpty) return;
    _drainScheduled = true;
    // 推到帧末：本方法是在 build 里被调的，别在 build 期间去解析图片。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _drainScheduled = false;
      _drain();
    });
  }

  /// 页面走了就停。已经在飞的那几张**不取消**——它们本来就是要热的，让它跑完更省事；
  /// 这里只是不再往里加新的。
  void dispose() {
    _disposed = true;
    _queue.clear();
  }

  /// 诊断用：到目前为止排过队的地址（按排队顺序）。测试拿它钉住窗口语义——
  /// 「只取前缘之后的一段、越界跳过、同一地址不重排」这三条改坏了不会静默。
  @visibleForTesting
  List<String> get debugQueued => List<String>.unmodifiable(_enqueued);

  void _drain() {
    while (!_disposed && _inFlight < concurrent && _queue.isNotEmpty) {
      final url = _queue.removeAt(0);
      _inFlight++;
      _warm(url).whenComplete(() {
        _inFlight--;
        if (!_disposed) _drain();
      });
    }
  }

  /// 自己 resolve，而不是用 `precacheImage`。
  ///
  /// `precacheImage` 要一个 `BuildContext`，只为拼出 `ImageConfiguration`；而缓存键里
  /// **没有** configuration 的位置——`CachedNetworkImageProvider.obtainKey` 直接返回自己、
  /// `loadImage` 也只读自己的字段（`cached_network_image_provider.dart`）。所以
  /// `ImageConfiguration.empty` 一样命中，顺带把 context 从这条链路上去掉了。
  ///
  /// 除了少了配置，这也正是 `precacheImage` 的实现形状：resolve → 挂 listener → 完成即
  /// 摘掉。摘掉 listener 不会把图从 `ImageCache` 里去掉（LRU 缓存与 live 计数是两回事），
  /// 所以热过的那张仍然会命中。
  Future<void> _warm(String url) {
    final stream = ResizeImage(
      CachedNetworkImageProvider(url),
      width: memCacheWidth,
    ).resolve(ImageConfiguration.empty);

    final completer = Completer<void>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      // 封面会过期（签名地址带 x-expires）也会 404。热不上就算了——真滑到那一张时组件
      // 自己会走 errorWidget。不吞掉的话，每个失败都会往控制台打一条 FlutterError。
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }
}
