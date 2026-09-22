import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import 'ranking_cache.dart';

/// 启动时把四个榜的第 1 页刷进 [RankingCache]。
///
/// 为什么需要：`RankingCache` 只在「进过榜单页、并且成功拉到第 1 页」之后才有内容，
/// 启动时**没有任何东西预热它**。而红果榜单约一半请求拿不到数据（见 `parseRanking`），
/// 页面为此要重试 6 次 × 退避（`BoardFeed._fetchWithRetry`）——第一次进榜单最坏要等
/// 十几秒。预热之后进页面是「先显示上次的、再后台刷新」，那段空白就没了。
///
/// **只热数据、不热封面**：内存里的封面会被首页滑动的封面挤掉（`ImageCache` 是 LRU、
/// 上限 100 MB），落盘的数据不会。
///
/// 走的是 web 主机（`hongguoduanju.com`，免签名），与启动时那轮剧库导入走的 app 主机
/// 不是同一个，所以两边不抢接口。
class RankingWarmer {
  RankingWarmer({required this.client, required this.cache});

  /// 每个榜最多试几次。
  ///
  /// 单次只有约五成成功率（上游在两种渲染之间摇摆），3 次约 87%。**刻意比页面自己的
  /// 6 次少**：预热失败并不致命——用户进页面时 `BoardFeed` 还会再试 6 次，而启动时
  /// 不值得为最后那几个百分点多打一轮。
  static const int maxAttempts = 3;

  /// 缓存比这还新就不重刷。
  ///
  /// 榜单每日更新，而用户可能一天里反复启动。刚热过就没必要再打一次——那点新鲜度换不来
  /// 什么，而缓存还新鲜时本来就「进页面就有」。清缓存会把榜单缓存一起清掉
  /// （`settings_page.dart`），所以清完之后这一条不会挡住重新预热。
  static const Duration freshEnough = Duration(minutes: 30);

  final HongguoClient client;
  final RankingCache cache;

  Future<void>? _inFlight;

  /// 跑一遍。已经在飞就搭车（与 [LibraryImporter.run] 同一个口径）。
  Future<void> run() {
    final existing = _inFlight;
    if (existing != null) return existing;
    late final Future<void> task;
    task = _run().whenComplete(() {
      if (identical(_inFlight, task)) _inFlight = null;
    });
    _inFlight = task;
    return task;
  }

  /// 四个榜**并发**跑：走的是 web 主机、与剧库导入不同路，而且一共就 4 个请求。
  Future<void> _run() async {
    final startedAt = DateTime.now();
    final results = await Future.wait([
      for (final board in rankingBoards) _warm(board),
    ]);
    // 刻意留的取证痕迹（同 `[library]`、`[prefetch]` 那两套）：启动预热热上了几个榜，
    // `adb logcat -s flutter` 里看得见。没热上的那几个进页面时会再试。
    debugPrint(
      '[ranking] 预热完成 · ${results.where((id) => id != null).length}/'
      '${rankingBoards.length} 个榜'
      ' · ${DateTime.now().difference(startedAt).inSeconds}s',
    );
  }

  /// 热一个榜。返回榜 id 表示热上了，null 表示跳过或失败。
  Future<String?> _warm(RankingBoard board) async {
    final cached = cache.read(board.id);
    if (cached != null &&
        DateTime.now().difference(cached.updatedAt) < freshEnough) {
      return board.id;
    }
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final page = await client.fetchRanking(board, 1);
        await cache.write(board.id, page);
        return board.id;
      } catch (_) {
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }
    // 全失败就算了：进榜单页时 `BoardFeed` 自己会再试 6 次，而且还有上次的缓存兜底。
    return null;
  }
}
