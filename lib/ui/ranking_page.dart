import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/providers.dart';
import '../data/ranking_cache.dart';
import 'cover_prefetch.dart';
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 榜单页：四个榜 + 名次列表。
///
/// **必须重试**：站点在两种渲染之间摇摆（约一半请求命中「新渲染」，那版 HTML 里压根
/// 没有榜单数据），详见 `parseRanking` 的注释。所以每个榜自动重试几次，而不是把一次
/// 失败当成站点改版。
///
/// **还要兜底**：全失败时退回上次成功的结果（`RankingCache`），并说清那是哪天的榜单。
/// 站点摇摆给一个错误页，比给一份旧榜没用得多。
class RankingsPage extends ConsumerStatefulWidget {
  const RankingsPage({super.key});

  @override
  ConsumerState<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends ConsumerState<RankingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: rankingBoards.length,
    vsync: this,
  );
  late final List<BoardFeed> _feeds = [
    for (final board in rankingBoards)
      BoardFeed(
        client: ref.read(hongguoClientProvider),
        board: board,
        cache: ref.read(rankingCacheProvider),
      ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_feeds.first.ensureLoaded());
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final feed in _feeds) {
      feed.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('榜单'),
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: palette.primaryText,
          unselectedLabelColor: palette.secondaryText,
          indicatorColor: palette.accent,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorWeight: 2.5,
          dividerColor: Colors.transparent,
          labelStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          onTap: (index) => unawaited(_feeds[index].ensureLoaded()),
          tabs: [for (final board in rankingBoards) Tab(text: board.name)],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [for (final feed in _feeds) _BoardView(feed: feed)],
      ),
    );
  }
}

/// 一个榜的分页列表。
///
/// 首次进入走 [ensureLoaded]：先把上次的结果显示出来（0 等待），同时后台刷新。刷新
/// 失败**保留**旧数据，只在顶部说清那是哪天的榜单。下拉刷新走 [refresh]，真正的翻页
/// 才走 [loadMore]。
class BoardFeed extends ChangeNotifier {
  BoardFeed({required this.client, required this.board, required this.cache});

  final HongguoClient client;
  final RankingBoard board;
  final RankingCache cache;

  final List<RankingItem> items = <RankingItem>[];

  /// 下一页要取的页码。**只有第 1 页成功之后**才会推进到 2，否则失败重试会取错页。
  int page = 1;
  int totalPages = 0;
  bool hasMore = true;
  bool loading = false;

  /// 失败信息。[items] 为空时是整页错误；非空时只在列表尾部提示。
  String? error;

  /// 当前这批数据来自缓存的时间。刷新成功后清空。
  DateTime? staleAt;

  /// 后台刷新失败过（此时 [staleAt] 仍非空——数据还在，只是没刷新成功）。
  bool refreshFailed = false;

  String updatedText = '';

  /// 自动重试的次数与节奏。
  ///
  /// 站点摇摆时**单次失败毫无意义**，连着失败才值得报给用户。但重试也不能太密——
  /// 间隔太短很可能又落到同一个边缘节点、拿到同一版页面（实测 4 次 × 300ms 全挂过）。
  /// 所以拉长到 6 次、间隔 0.5–2.5 秒。
  static const int maxAutoRetries = 6;
  int _attempts = 0;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 在途请求回来时页面可能已经走了，直接 notifyListeners 会抛。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 顶部那行文案。优先说清「这是旧数据」，没有再退回上游的「每日更新」。
  String get statusText {
    final at = staleAt;
    if (at == null) return updatedText;
    final date = '${at.month}月${at.day}日';
    return refreshFailed
        ? '刷新失败，显示 $date 的榜单'
        : '上次更新 $date · 正在刷新…';
  }

  /// 首次进入：先显示上次的，再后台刷新。已经加载过就不重来（来回切 tab 不该重拉）。
  Future<void> ensureLoaded() async {
    if (items.isNotEmpty) return;
    _restoreFromCache();
    await _refreshFirstPage();
  }

  void _restoreFromCache() {
    final cached = cache.read(board.id);
    if (cached == null) return;
    items
      ..clear()
      ..addAll(cached.items);
    totalPages = cached.totalPages;
    hasMore = cached.totalPages > page;
    updatedText = cached.updatedText;
    staleAt = cached.updatedAt;
    refreshFailed = false;
    _notify();
  }

  /// 正在飞的那次「取第 1 页」。见 [_refreshFirstPage]。
  Future<void>? _refreshing;

  /// 取第 1 页并**替换**内容。失败时保留现有 [items]（有缓存时就是那份旧榜）。
  ///
  /// 已经有一个在飞就**复用**它，而不是再发一个：`ensureLoaded` 在「没有缓存 + 首次请求
  /// 很慢」时会被反复触发（连点 tab、切回来）。复用也让下拉刷新能等到同一个请求，指示器
  /// 不会一闪而过。
  Future<void> _refreshFirstPage() {
    final running = _refreshing;
    if (running != null) return running;
    final task = _runRefreshFirstPage();
    _refreshing = task;
    return task.whenComplete(() {
      if (identical(_refreshing, task)) _refreshing = null;
    });
  }

  Future<void> _runRefreshFirstPage() async {
    loading = true;
    error = null;
    _notify();

    final result = await _fetchWithRetry(1);
    loading = false;

    if (result == null) {
      refreshFailed = items.isNotEmpty;
      if (items.isEmpty) {
        error = _failureText();
        hasMore = false;
      }
      _notify();
      return;
    }

    items
      ..clear()
      ..addAll(result.items);
    totalPages = result.totalPages;
    updatedText = result.updatedText;
    page = 2;
    hasMore = result.hasMore;
    staleAt = null;
    refreshFailed = false;
    error = null;
    _notify();
    await cache.write(board.id, result);
  }

  /// 下拉刷新。失败也不清列表——宁可留着旧的，也不要刷出一片空白。
  Future<void> refresh() => _refreshFirstPage();

  /// 翻页。第 1 页还没成功过就没有「下一页」可言。
  Future<void> loadMore() async {
    if (loading || !hasMore || page < 2) return;
    loading = true;
    error = null;
    _notify();

    final result = await _fetchWithRetry(page);
    loading = false;

    if (result == null) {
      // 停在这页：继续滚不该反复打同一个必挂的请求。
      error = _failureText();
      hasMore = false;
      _notify();
      return;
    }

    items.addAll(result.items);
    totalPages = result.totalPages;
    updatedText = result.updatedText;
    hasMore = result.hasMore;
    page += 1;
    _notify();
  }

  /// 整页出错时的重试按钮。
  Future<void> retry() async {
    error = null;
    hasMore = true;
    refreshFailed = false;
    _attempts = 0;
    _restoreFromCache();
    await _refreshFirstPage();
  }

  Future<RankingPage?> _fetchWithRetry(int target) async {
    for (var attempt = 1; attempt <= maxAutoRetries; attempt++) {
      _attempts = attempt;
      try {
        return await client.fetchRanking(board, target);
      } catch (_) {
        if (attempt < maxAutoRetries) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }
    return null;
  }

  String _failureText() =>
      '榜单暂时取不到：站点在两种页面版本之间切换，试了 $_attempts 次都没拿到。'
      '换个榜或稍后再试。';
}

class _BoardView extends StatefulWidget {
  const _BoardView({required this.feed});

  final BoardFeed feed;

  @override
  State<_BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<_BoardView> {
  final ScrollController _scroll = ScrollController();

  /// 封面预取。行封面走 [rowCoverWidth]——**必须与 [_RankingRow] 里那张图给的值一致**。
  ///
  /// 榜单比首页更值得热：进榜页会先把上次缓存的**整页 20 行**一口气铺出来
  /// （`BoardFeed.ensureLoaded` 的 `_restoreFromCache`），那就是「20 张封面同时开抢」。
  final CoverPrefetcher _prefetch = CoverPrefetcher(
    memCacheWidth: rowCoverWidth,
  );

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_onChanged);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.feed.removeListener(_onChanged);
    _scroll.dispose();
    _prefetch.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 500) unawaited(widget.feed.loadMore());
  }

  /// 封面地址。列表下标 0 是顶部那行状态、末尾多一条页脚，所以要减 1。
  String _coverAt(int index) {
    final items = widget.feed.items;
    final position = index - 1;
    return position >= 0 && position < items.length
        ? items[position].drama.cover
        : '';
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final palette = OneDramaColors.of(context);

    if (feed.items.isEmpty && feed.loading) {
      return Center(
        child: CircularProgressIndicator(
          color: palette.accent,
          strokeWidth: 2.5,
        ),
      );
    }
    if (feed.items.isEmpty && feed.error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.emoji_events_outlined,
              size: 40,
              color: palette.secondaryText,
            ),
            const SizedBox(height: 14),
            Text(
              feed.error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: palette.secondaryText,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => unawaited(feed.retry()),
              style: FilledButton.styleFrom(backgroundColor: palette.accent),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: palette.accent,
      // 不先清空：刷新失败时那份旧榜要留在屏幕上，见 BoardFeed.refresh。
      onRefresh: feed.refresh,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          OneDramaSizes.pagePadding,
          10,
          OneDramaSizes.pagePadding,
          24,
        ),
        itemCount: feed.items.length + 2,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          // 把「构建到哪了」报给预取器，它会去热紧接着的那一屏封面。
          _prefetch.advanceTo(index, _coverAt);
          if (index == 0) {
            final status = feed.statusText;
            return status.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        color: feed.staleAt == null
                            ? palette.secondaryText
                            : palette.accent,
                      ),
                    ),
                  );
          }
          if (index == feed.items.length + 1) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: feed.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        feed.error ?? (feed.hasMore ? '' : '没有更多了'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.secondaryText,
                        ),
                      ),
              ),
            );
          }
          final item = feed.items[index - 1];
          return _RankingRow(
            item: item,
            rank: index,
            // 标签里带榜 ID：榜单是 `TabBarView`，滑动时相邻两个榜同时在树里，
            // 而同一部剧可能同时挂在「总热播」和「真人」上。
            heroTag: coverHeroTag('rank:${feed.board.id}', item.drama.id),
          );
        },
      ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.item,
    required this.rank,
    required this.heroTag,
  });

  final RankingItem item;

  /// 列表里的第几行（1 基）。名次本身用 `item.rank`。
  final int rank;

  /// 封面的 Hero 标签。两端一致才会飞（见 [coverHeroTag]）。
  final String heroTag;

  /// 前三名给个强调色。色板要按亮度取，所以只能从 build 里传进来。
  Color _rankColor(OneDramaColors palette) => switch (rank) {
    1 => const Color(0xFFE8A33D),
    2 => const Color(0xFF9AA0A8),
    3 => const Color(0xFFC08457),
    _ => palette.secondaryText,
  };

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Pressable(
      onTap: () => openDrama(context, item.drama, heroTag: heroTag),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              '${item.rank}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: rank <= 3 ? 20 : 16,
                fontWeight: FontWeight.w800,
                fontStyle: FontStyle.italic,
                color: _rankColor(palette),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 58,
              height: 78,
              child: Hero(
                tag: heroTag,
                child: DramaCover(
                  url: item.drama.cover,
                  memCacheWidth: rowCoverWidth,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.drama.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: palette.primaryText,
                  ),
                ),
                const SizedBox(height: 6),
                if (item.metric.isNotEmpty)
                  Text(
                    item.metric,
                    style: TextStyle(fontSize: 12, color: palette.accent),
                  ),
                if (item.drama.tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.drama.tags.take(3).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.secondaryText,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
