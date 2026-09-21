import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/catalog_pager.dart';
import '../data/database.dart';
import '../data/library_tabs.dart';
import '../data/providers.dart';
import 'cover_prefetch.dart';
import 'player_page.dart';
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 题材快捷词。
///
/// 红果没有题材词表接口、也没法传筛选排序（见 `docs/plan.md`），所以这些 chip 点下去
/// 是**跳搜索**——是快捷搜索词，不是筛选器。UI 上不说破，但行为要一致。
const List<String> libraryTopics = <String>[
  '甜宠',
  '逆袭',
  '复仇',
  '穿越',
  '热血',
  '治愈',
  '玄幻',
  '战神',
  '重生',
  '年代',
];

/// 一个标签下的信息流：**本地快照优先，网络跟上**。
///
/// 用 `ChangeNotifier` 而不是 Riverpod 的 family notifier：分页状态只属于这一个页面，
/// 没必要进全局容器；收藏、历史那些要跨页共享的才放 provider。
class LibraryFeed extends ChangeNotifier {
  LibraryFeed({
    required this.client,
    required this.database,
    required this.tab,
    required this.tabIndex,
  }) : _pager = CatalogPager(client: client, tab: tab);

  final HongguoClient client;
  final AppDatabase database;
  final LibraryTab tab;

  /// 标签下标。剧库快照按它取（`library_entries.tab`）。
  final int tabIndex;

  CatalogPager _pager;

  final List<Drama> dramas = <Drama>[];

  bool loading = false;
  bool hasMore = true;
  String? error;

  bool _started = false;

  /// 首次进入这个标签时才真正拉数据——四个标签一次全拉是浪费。
  Future<void> ensureLoaded() async {
    if (_started) return;
    _started = true;
    // ① 本地优先：有快照就先画出来，**一个请求都不等**（见 `docs/adr/0008`）。
    final local = await database.libraryTab(tabIndex);
    if (local.isNotEmpty) {
      dramas.addAll(local);
      notifyListeners();
    }
    // ② 再看一眼网络。本地已经有内容时，这一趟只做「头部有没有新剧」的检查、把新剧插到
    //    最前，**不整页替换**：「综合」走的是推荐流，每页都不一样，整页换会让用户眼前
    //    的列表自己跳一次。
    await _pull(atTop: local.isNotEmpty);
  }

  /// 下拉刷新。用户明确要最新的，所以**整页换掉**（与上面那条自动检查区别对待）。
  ///
  /// 只改内存、不落盘：快照的唯一写入者是「更新剧库」——下拉刷新落一份只有 18 条的
  /// 快照，会把另外 72 部离线可看的剧删掉，那不是用户按这个手势想要的结果。
  Future<void> refresh() async {
    dramas.clear();
    _pager = CatalogPager(client: client, tab: tab);
    hasMore = true;
    error = null;
    _started = true;
    notifyListeners();
    await _pull(atTop: true);
  }

  Future<void> loadMore() => _pull(atTop: false);

  Future<void> _pull({required bool atTop}) async {
    if (loading || !hasMore) return;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final fresh = await _pager.next();
      _absorb(fresh, atTop: atTop);
      hasMore = !_pager.exhausted;
    } catch (failure) {
      // 报错但**不**把 hasMore 关掉：用户重试时还要能继续翻。
      error = '$failure';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 并进列表。规则见 [absorbDramas]。
  void _absorb(List<Drama> fresh, {required bool atTop}) =>
      absorbDramas(dramas, fresh, atTop: atTop);
}

/// 把网络新拉到的一页并进列表，返回真的插进去了几条。
///
/// [atTop] 为真表示这是「头部有没有新剧」的检查（往**最前**插），为假表示向后翻页（往
/// 最后接）。两种都按 ID 去重：本地快照与网络分页覆盖的本来就是同一批剧。
///
/// 抽成顶层函数是为了能单测——这条规则很容易写反，而写反的症状很隐蔽：插到尾部时首页
/// 看上去一切正常，只是**新剧永远排在几十部缓存之后**，没人滑得到。
int absorbDramas(List<Drama> into, List<Drama> fresh, {required bool atTop}) {
  final known = {for (final drama in into) drama.id};
  final added = <Drama>[];
  for (final drama in fresh) {
    if (drama.id.isEmpty || !known.add(drama.id)) continue;
    added.add(drama);
  }
  if (added.isEmpty) return 0;
  if (atTop) {
    into.insertAll(0, added);
  } else {
    into.addAll(added);
  }
  return added.length;
}

/// 短剧库。参考页的信息架构：搜索 → 一级标签 → 题材 chip → 双列海报流。
///
/// 页头（搜索 + 标签 + chip）固定，只有内容区滚动——参考页就是这个结构，也比把页头
/// 塞进 sliver 里稳。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final PageController _pages = PageController();
  late final List<LibraryFeed> _feeds;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _feeds = [
      for (var index = 0; index < libraryTabs.length; index++)
        LibraryFeed(
          client: ref.read(hongguoClientProvider),
          database: ref.read(databaseProvider),
          tab: libraryTabs[index],
          tabIndex: index,
        ),
    ];
    _feeds.first.ensureLoaded();
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final feed in _feeds) {
      feed.dispose();
    }
    super.dispose();
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    setState(() => _tab = index);
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    _feeds[index].ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cardWidth =
        (width - OneDramaSizes.pagePadding * 2 - OneDramaSizes.gridGap) / 2;
    // 卡片高度 = 海报 + 标题两行 + 副标题。写死比例会在窄屏/大字号下裁掉文字。
    final cardHeight = cardWidth / OneDramaSizes.posterAspect + 66;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _SearchRow(),
            _TabsRow(current: _tab, onSelect: _selectTab),
            const _TopicChips(),
            const _ContinueWatching(),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: libraryTabs.length,
                onPageChanged: (index) {
                  if (index == _tab) return;
                  setState(() => _tab = index);
                  _feeds[index].ensureLoaded();
                },
                itemBuilder: (context, index) => _FeedView(
                  feed: _feeds[index],
                  tabIndex: index,
                  cardAspectRatio: cardWidth / cardHeight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索框那一行。搜索框本身是个只读的“假输入框”，点了跳搜索页——
/// 真输入放在搜索页里，避免首页键盘弹起把列表顶飞。
class _SearchRow extends StatelessWidget {
  const _SearchRow();

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        8,
        OneDramaSizes.pagePadding,
        10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Pressable(
              onTap: () => context.push('/search'),
              scale: 0.98,
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: palette.field,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(Icons.search, size: 20, color: palette.secondaryText),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '搜索剧名、题材或标签',
                        style: TextStyle(
                          fontSize: 14,
                          color: palette.secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 参考页里搜索框右边有个方块，是「继续观看」的快捷入口。浅色下是黑底白图标；
          // 深色下（深色参考图）仍是深底、图标换成强调色——这里不能写成
          // `primaryText` 取反，那会在深色下变成一整块白。
          Pressable(
            onTap: () => context.go('/mine'),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDark ? palette.field : palette.primaryText,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: isDark ? palette.accent : Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一级标签 + 右上的榜单入口。
class _TabsRow extends StatelessWidget {
  const _TabsRow({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OneDramaSizes.pagePadding,
      ),
      child: Row(
        children: [
          for (var index = 0; index < libraryTabs.length; index++)
            _TabButton(
              label: libraryTabs[index].label,
              selected: index == current,
              onTap: () => onSelect(index),
            ),
          const Spacer(),
          IconButton(
            tooltip: '榜单',
            onPressed: () => context.push('/rank'),
            icon: const Icon(Icons.emoji_events_outlined, size: 22),
            color: palette.primaryText,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Pressable(
      onTap: onTap,
      behavior: HitTestBehavior.deferToChild,
      scale: 0.94,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: selected ? 17 : 15.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? palette.primaryText : palette.secondaryText,
              ),
              child: Text(label),
            ),
            const SizedBox(height: 4),
            // 选中下划线。用高度动画而不是位移，省一次布局测量。
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: selected ? 2.5 : 0,
              width: 16,
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 题材快捷词。点了跳搜索（不是筛选）。
class _TopicChips extends StatelessWidget {
  const _TopicChips();

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    // 参考图里 chip 文字浅色下是主文字色，深色下换成次文字色的灰——暗底上白字太抢眼。
    final chipText = Theme.of(context).brightness == Brightness.dark
        ? palette.secondaryText
        : palette.primaryText;
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: OneDramaSizes.pagePadding,
          vertical: 6,
        ),
        itemCount: libraryTopics.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final topic = libraryTopics[index];
          return Pressable(
            onTap: () => context.push('/search?q=$topic'),
            scale: 0.94,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: palette.field,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                topic,
                style: TextStyle(fontSize: 13.5, color: chipText),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 首页的「上次观看」快速入口。参考图里它夹在题材 chip 与海报流之间。
///
/// 取历史里最近的一条（[historyProvider] 已按最后观看时间倒序）。点一下**直接开播**，
/// 不绕详情页——所以要先取一次详情才能拿到分集列表，期间右上角那个圆钮转圈。
/// 没有历史时整块不出现，也不占位：新用户看到的还是干净的首屏。
class _ContinueWatching extends ConsumerStatefulWidget {
  const _ContinueWatching();

  @override
  ConsumerState<_ContinueWatching> createState() => _ContinueWatchingState();
}

class _ContinueWatchingState extends ConsumerState<_ContinueWatching> {
  bool _opening = false;

  /// 「00:07」这种。播放页里那份是私有的，这里就三行，不为了共用一个函数绕一圈。
  static String _clock(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _resume(HistoryEntry entry) async {
    if (_opening) return;
    final seriesId = entry.drama.sourceId;
    if (seriesId.isEmpty) return;
    setState(() => _opening = true);
    try {
      final detail = await ref.read(detailProvider(seriesId).future);
      if (!mounted) return;
      // 分集列表里找不到那条 videoId（站点换了集？）就从头开始，别续到一个错的集上。
      final index = detail.episodes.indexWhere(
        (item) => item.videoId == entry.videoId,
      );
      openPlayer(
        context,
        drama: entry.drama,
        episodes: detail.episodes,
        index: index < 0 ? 0 : index,
        startAt: index < 0 ? 0 : entry.positionMs,
      );
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('续播失败：$failure'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider).value;
    if (history == null || history.isEmpty) return const SizedBox.shrink();

    final entry = history.first;
    final palette = OneDramaColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        0,
        OneDramaSizes.pagePadding,
        10,
      ),
      child: Pressable(
        onTap: () => _resume(entry),
        scale: 0.98,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(OneDramaSizes.cardRadius),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 42,
                  height: 56,
                  // 这一处刻意**不套 Hero**：它显示的往往就是下面网格里的第一张
                  // （实测过：上次看的是「破晓」，网格首卡也是「破晓」），同一条路由里
                  // 就会出现两个同标签的 Hero，Flutter 会抛「multiple heroes that share
                  // the same tag」。网格那张是主路径，标签留给它。
                  child: DramaCover(
                    url: entry.drama.cover,
                    memCacheWidth: rowCoverWidth,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.drama.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: palette.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '上次看到第 ${entry.episodeNumber} 集 · '
                      '${_clock(Duration(milliseconds: entry.positionMs))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 参考图里右侧是个粉色圆形播放键。取详情期间它转圈，免得连点两次。
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.accent,
                  shape: BoxShape.circle,
                ),
                child: _opening
                    ? const Padding(
                        padding: EdgeInsets.all(11),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个标签的内容区：下拉刷新 + 双列海报流 + 底部状态。
class _FeedView extends StatefulWidget {
  const _FeedView({
    required this.feed,
    required this.tabIndex,
    required this.cardAspectRatio,
  });

  final LibraryFeed feed;

  /// 一级标签的下标。只用来拼封面 Hero 标签（见 [coverHeroTag]）——首页是 `PageView`，
  /// 滑动时相邻两个标签同时在树里，标签必须带上它才唯一。
  final int tabIndex;

  final double cardAspectRatio;

  @override
  State<_FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<_FeedView> {
  final ScrollController _scroll = ScrollController();

  /// 封面预取。网格海报走 [gridCoverWidth]——**必须与 [DramaCard] 里那张图给的值一致**，
  /// 否则缓存键不同、热了也白热。
  final CoverPrefetcher _prefetch = CoverPrefetcher(
    memCacheWidth: gridCoverWidth,
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

  /// 提前一屏开始加载下一页，滑到底时通常已经就绪。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) widget.feed.loadMore();
  }

  /// 封面地址。预取器会拿它去问「紧接着的那几条」是哪些。
  String _coverAt(int index) {
    final dramas = widget.feed.dramas;
    return index < dramas.length ? dramas[index].cover : '';
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;

    return RefreshIndicator(
      color: OneDramaColors.of(context).accent,
      onRefresh: feed.refresh,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (feed.dramas.isEmpty && feed.loading)
            const SliverFillRemaining(hasScrollBody: false, child: _Loading())
          else if (feed.dramas.isEmpty && feed.error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ErrorView(
                message: feed.error!,
                onRetry: () {
                  feed.error = null;
                  feed.loadMore();
                },
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                OneDramaSizes.pagePadding,
                2,
                OneDramaSizes.pagePadding,
                8,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: OneDramaSizes.gridGap,
                  childAspectRatio: widget.cardAspectRatio,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  // 把「构建到哪了」报给预取器，它会去热紧接着的那一屏封面。
                  _prefetch.advanceTo(index, _coverAt);
                  final drama = feed.dramas[index];
                  final tag = coverHeroTag('t${widget.tabIndex}', drama.id);
                  return DramaCard(
                    drama: drama,
                    heroTag: tag,
                    onTap: () => openDrama(context, drama, heroTag: tag),
                  );
                }, childCount: feed.dramas.length),
              ),
            ),
          SliverToBoxAdapter(child: _Footer(feed: feed)),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Center(
    child: CircularProgressIndicator(
      color: OneDramaColors.of(context).accent,
      strokeWidth: 2.5,
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 40,
            color: palette.secondaryText,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.secondaryText),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(backgroundColor: palette.accent),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 底部状态：加载中 / 到底了 / 出错可重试。
class _Footer extends StatelessWidget {
  const _Footer({required this.feed});

  final LibraryFeed feed;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (feed.error != null && feed.dramas.isNotEmpty) {
      child = TextButton(
        onPressed: () {
          feed.error = null;
          feed.loadMore();
        },
        child: const Text('加载失败，点这里重试'),
      );
    } else if (feed.loading) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (!feed.hasMore && feed.dramas.isNotEmpty) {
      child = Text(
        '没有更多了',
        style: TextStyle(
          fontSize: 12,
          color: OneDramaColors.of(context).secondaryText,
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(child: child),
    );
  }
}
