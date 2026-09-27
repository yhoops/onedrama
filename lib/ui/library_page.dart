import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/catalog_pager.dart';
import '../data/database.dart';
import '../data/library_filter.dart';
import '../data/library_tabs.dart';
import '../data/providers.dart';
import 'cover_prefetch.dart';
import 'player_page.dart';
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 综合标签的题材快捷词。
///
/// **仅综合标签用**：综合走推荐流、网页无等价物，做不了服务端题材筛选，所以这些 chip
/// 点下去是**跳搜索**（快捷搜索词，不是筛选器）。分类标签（真人剧/漫剧/AI剧）改用官方
/// 题材词表做真正的服务端筛选（协议层 `categoryThemes`）——「红果没有题材词表接口」那个
/// 旧前提只对 App 接口成立，网页分类页的 `selectorList` 是有词表的（见任务 09-27-tag-filter）。
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

  /// 当前生效的题材筛选（`selector_item_id`）；null 表示未筛选。
  ///
  /// 只属于这个标签，不进全局容器——切标签时各自保留自己的筛选态（配合 keepAlive）。
  String? theme;

  /// 本地筛选 / 排序（「轻量筛选」浮层用）。题材走服务端（[theme]），这三个是纯展示层
  /// 变换，叠在已加载的 [dramas] 之上，不落盘、不动分页。
  LibraryStatus status = LibraryStatus.any;
  bool withinSixty = false;
  LibrarySort sort = LibrarySort.none;

  /// 实际展示的列表：在 [dramas] 上叠本地状态/篇幅过滤与排序（题材已在服务端筛过）。
  List<Drama> get visibleDramas => applyLibraryFilters(
        dramas,
        status: status,
        withinSixty: withinSixty,
        sort: sort,
      );

  /// 应用浮层里的本地条件（无网络）。题材由 [setTheme] 单独处理。
  void applyLocalFilters({
    required LibraryStatus status,
    required bool withinSixty,
    required LibrarySort sort,
  }) {
    this.status = status;
    this.withinSixty = withinSixty;
    this.sort = sort;
    notifyListeners();
  }

  /// 首次进入这个标签时才真正拉数据——四个标签一次全拉是浪费。
  Future<void> ensureLoaded() async {
    if (_started) return;
    _started = true;
    final pagerAtStart = _pager;
    // ① 本地优先：有快照就先画出来，**一个请求都不等**（见 `docs/adr/0008`）。
    final local = await database.libraryTab(tabIndex);
    // 这期间用户可能已经切了题材：`setTheme` 会重建 pager、清空列表，而快照是**未筛选**
    // 的全量数据——再并进去会把筛掉的内容混回来（症状：结果里混进不属于该题材的剧，
    // 且偶发）。pager 变了就整趟作废，交给那次 setTheme 自己拉。
    if (!identical(_pager, pagerAtStart)) return;
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
    // 下拉刷新要保留当前题材筛选：筛选态下重建的仍是网页筛选 pager，否则会悄悄
    // 掉回未筛选流、而 chip 还高亮着，前后对不上。
    _pager = CatalogPager(
      client: client,
      tab: tab,
      filterRoute: theme == null ? null : themedCategoryRoute(tab.webRoute, theme!),
    );
    hasMore = true;
    error = null;
    _started = true;
    notifyListeners();
    await _pull(atTop: true);
  }

  Future<void> loadMore() => _pull(atTop: false);

  /// 切换题材筛选。[themeId] 为 null 回到未筛选流。
  ///
  /// 筛选态走**网页服务端筛选**（`/category/<类型>/<题材>`），是 network-only 的：
  /// 不读快照、不落盘——题材结果是可重建的浏览态，与「下拉刷新不落盘」同口径。回到
  /// 未筛选时才恢复「本地优先」（App 源 + 快照）。
  Future<void> setTheme(String? themeId) async {
    if (theme == themeId) return;
    theme = themeId;
    dramas.clear();
    hasMore = true;
    error = null;

    if (themeId == null) {
      // 回未筛选：重建普通 pager，走回本地优先。
      _pager = CatalogPager(client: client, tab: tab);
      _started = false;
      notifyListeners();
      await ensureLoaded();
      return;
    }

    // 题材筛选：网页源 pager，直接拉第一页（整页替换，不读快照）。
    _pager = CatalogPager(
      client: client,
      tab: tab,
      filterRoute: themedCategoryRoute(tab.webRoute, themeId),
    );
    _started = true;
    notifyListeners();
    await _pull(atTop: true);
  }

  Future<void> _pull({required bool atTop}) async {
    if (loading || !hasMore) return;
    // 记下这次用的是哪个 pager。拉的过程中用户可能切了题材（`setTheme` 会换掉 `_pager`），
    // 那一批数据属于**旧筛选**，并进来会污染当前结果——pager 变了就整批丢弃。
    final pagerAtStart = _pager;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final fresh = await _pager.next();
      if (!identical(_pager, pagerAtStart)) return;
      _absorb(fresh, atTop: atTop);
      hasMore = !_pager.exhausted;
    } catch (failure) {
      if (!identical(_pager, pagerAtStart)) return;
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

  /// 启动预热另外三个标签的首屏封面用的。窗口只有一屏，与 `_FeedViewState` 里那个
  /// 12 窗口的滚动预取器分工不同——见 [CoverPrefetcher.firstScreen]。
  late final CoverPrefetcher _warm = CoverPrefetcher(
    memCacheWidth: gridCoverWidth,
    window: CoverPrefetcher.firstScreen,
  );

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

    // 启动后预热另外三个标签的首屏封面。
    //
    // **首访那一下卡顿不是数据**：实测一个标签 86 行、94 KB 的 payload 解析成 Drama
    // 只要 2–5 ms（JIT 上界，真机 AOT 更快），读库那次也是异步的。卡的是封面——约
    // 4–6 张海报要在 260 ms 的转场里走完「磁盘读 → 解码 → 显存上传」，还要叠 220 ms
    // 淡入。所以把这段活挪到启动后来干：那时用户还没开始交互，是最便宜的窗口。热过的
    // 封面连淡入都不放（`octo_image` 的 `wasSynchronouslyLoaded` 分支），切过去直接出图。
    //
    // **必须先 `ensureLoaded` 再热**：`LibraryFeed` 会把新拉到的那一页插到最前
    // （见 [absorbDramas]），只按快照热的话，恰好在新剧上架时热的会是被挤下去的旧那几张。
    // 先加载 feed 的**净请求代价约 0**——它拉的第一页会被 TTL 缓存住，导入器随后拉同一页
    // 时直接命中（`network.dart` 的白名单里有 `/reading/distribution/category/`）。
    //
    // 推到第一帧之后：它要解码几十张图，绝不能挡启动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_warmOtherTabs());
    });
  }

  /// 按标签下标顺序**串行**热另外三个标签的首屏。
  ///
  /// 串行是刻意的：同时最多只有 `CoverPrefetcher` 自己那 3 张在飞，而当前标签（综合）
  /// 的首屏要抢同一批解码与显存上传——让它先赢。顺序即下标顺序，也就是最可能被切到的
  /// 「真人剧」排在最前。
  Future<void> _warmOtherTabs() async {
    final startedAt = DateTime.now();
    final queued = <int, int>{};
    for (var index = 0; index < _feeds.length; index++) {
      // 用户可能已经切过去了：那一页的封面本来就在画，再热一遍是白费。
      if (index == _tab) continue;
      final feed = _feeds[index];
      await feed.ensureLoaded();
      if (!mounted) return;
      final dramas = feed.dramas;
      queued[index] = dramas
          .take(CoverPrefetcher.firstScreen)
          .where((drama) => drama.cover.isNotEmpty)
          .length;
      _warm.warmFrom(0, (at) => at < dramas.length ? dramas[at].cover : '');
    }
    // 刻意留的取证痕迹（同 `[library]` / `[ranking]` 那两套）：预热到底排了多少张。
    // **不能只看内存**——封面源图是 400px 宽的 HEIC（URL 里 `aifit:400:0`），
    // `gridCoverWidth` 那个 480 比源图还大、缩不下来，所以每张约 1.14 MB；
    // 而 `dumpsys meminfo` 对 Impeller 的纹理记账并不完整，量不出这个数。
    debugPrint(
      '[warm] 首屏预热排队 · 逐标签 '
      '${queued.entries.map((e) => '${e.key}:${e.value}').join(' ')}'
      ' · ${DateTime.now().difference(startedAt).inMilliseconds}ms',
    );
  }

  @override
  void dispose() {
    _pages.dispose();
    _warm.dispose();
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

  /// 打开「轻量筛选」浮层，作用于当前标签的信息流。
  void _openFilterSheet() {
    final feed = _feeds[_tab];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FilterSheet(tab: libraryTabs[_tab], feed: feed),
    );
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
            _TabsRow(
              current: _tab,
              onSelect: _selectTab,
              onOpenFilter: _openFilterSheet,
            ),
            _TopicChips(tab: libraryTabs[_tab], feed: _feeds[_tab]),
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
  const _TabsRow({
    required this.current,
    required this.onSelect,
    required this.onOpenFilter,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenFilter;

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
          // 筛选入口：紧挨榜单图标。点开「轻量筛选」浮层，作用于当前标签的信息流。
          Pressable(
            onTap: onOpenFilter,
            semanticLabel: '筛选',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.filter_list, size: 20, color: palette.primaryText),
                  const SizedBox(width: 3),
                  Text(
                    '筛选',
                    style: TextStyle(fontSize: 14, color: palette.primaryText),
                  ),
                ],
              ),
            ),
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

/// 题材 chip 行。
///
/// - **分类标签（真人剧/漫剧/AI剧）**：官方题材词表，单选**筛选器**——点一个就地把信息流
///   换成 `/category/<类型>/<题材>` 的服务端结果，点已选项再点=取消。跟着 [feed] 重建以
///   高亮当前选中的题材。
/// - **综合标签**：网页无推荐等价物、无法筛，保持原样——`libraryTopics` 是**跳搜索的
///   快捷词**（不是筛选），点了 push 到搜索页。
class _TopicChips extends StatelessWidget {
  const _TopicChips({required this.tab, required this.feed});

  final LibraryTab tab;
  final LibraryFeed feed;

  @override
  Widget build(BuildContext context) {
    if (!tab.isCategory) return const _SearchShortcutChips();
    final themes = themesForWebRoute(tab.webRoute);
    if (themes.isEmpty) return const SizedBox.shrink();
    // 跟着 feed 走：setTheme 后要重画高亮。
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) => _FilterChips(
        themes: themes,
        selected: feed.theme,
        onToggle: (id) => feed.setTheme(feed.theme == id ? null : id),
      ),
    );
  }
}

/// 综合标签的题材快捷词。点了跳搜索（不是筛选）。
class _SearchShortcutChips extends StatelessWidget {
  const _SearchShortcutChips();

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

/// 分类标签的题材筛选 chip：单选，选中用强调色实心。
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.themes,
    required this.selected,
    required this.onToggle,
  });

  final List<CategoryTheme> themes;
  final String? selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final idleText = Theme.of(context).brightness == Brightness.dark
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
        itemCount: themes.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final theme = themes[index];
          final isOn = theme.id == selected;
          return Pressable(
            onTap: () => onToggle(theme.id),
            scale: 0.94,
            semanticLabel: '题材 ${theme.name}${isOn ? ' 已选中' : ''}',
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isOn ? palette.accent : palette.field,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                theme.name,
                style: TextStyle(
                  fontSize: 13.5,
                  color: isOn ? Colors.white : idleText,
                  fontWeight: isOn ? FontWeight.w600 : FontWeight.w400,
                ),
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

class _FeedViewState extends State<_FeedView>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  /// 封面预取。网格海报走 [gridCoverWidth]——**必须与 [DramaCard] 里那张图给的值一致**，
  /// 否则缓存键不同、热了也白热。
  final CoverPrefetcher _prefetch = CoverPrefetcher(
    memCacheWidth: gridCoverWidth,
  );

  /// 当前实际展示的列表（本地筛选/排序后）。在 build 里刷新，供网格与预取器共用同一份，
  /// 免得预取器按 `dramas` 的下标去热、而网格显示的是筛过的另一批，热错。
  List<Drama> _visible = const <Drama>[];

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
  String _coverAt(int index) =>
      index < _visible.length ? _visible[index].cover : '';

  /// 切标签时不销毁这一页。
  ///
  /// `PageView` 默认把滑走的页整个 dispose，切回来整棵树重建——封面重走「磁盘读 →
  /// 解码 → `DramaCover` 那 220ms 淡入」，那一下闪就是它。保住这一页之后封面不再重
  /// 解码，滚动位置也留住了（底部三页已经是这个口径，见 `home_shell.dart`）。
  ///
  /// 代价：四个标签各自的最后一屏都留在内存里，约等于四倍的单标签开销。每张网格封面
  /// 按 `gridCoverWidth` 解出来约 1.32 MB（见 `drama_card.dart`），量级几十 MB——
  /// 而 `ImageCache` 默认上限是 100 MB，这个数**真机上要量**。
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // `AutomaticKeepAliveClientMixin` 要求；不调的话 wantKeepAlive 不生效。
    super.build(context);
    final feed = widget.feed;
    _visible = feed.visibleDramas;

    return RefreshIndicator(
      color: OneDramaColors.of(context).accent,
      onRefresh: feed.refresh,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (_visible.isEmpty && feed.dramas.isEmpty && feed.loading)
            const SliverFillRemaining(hasScrollBody: false, child: _Loading())
          else if (_visible.isEmpty && feed.dramas.isEmpty && feed.error != null)
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
          else if (_visible.isEmpty)
            // 有加载到剧、但被本地筛选条件筛没了（或本地库为空、非加载中）。
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyFilter(),
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
                  final drama = _visible[index];
                  final tag = coverHeroTag('t${widget.tabIndex}', drama.id);
                  return DramaCard(
                    drama: drama,
                    heroTag: tag,
                    onTap: () => openDrama(context, drama, heroTag: tag),
                  );
                }, childCount: _visible.length),
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

/// 本地筛选把这一页筛空了（或本地库为空）时的占位。区别于网络错误：这里没出错，
/// 只是「按当前条件没有」。
class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter();

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.filter_alt_off_outlined,
              size: 40, color: palette.secondaryText),
          const SizedBox(height: 12),
          Text(
            '没有符合筛选条件的短剧',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.secondaryText),
          ),
        ],
      ),
    );
  }
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

/// 段标题（题材 / 状态·篇幅 / 排序）。
class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: OneDramaColors.of(context).primaryText,
          ),
        ),
      );
}

/// 浮层里的单个选项 chip：选中用强调色实心（同信息流那排 `_FilterChips` 的观感）。
class _SheetChip extends StatelessWidget {
  const _SheetChip({
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
      scale: 0.95,
      semanticLabel: '$label${selected ? ' 已选中' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? palette.accent : palette.field,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: selected ? Colors.white : palette.primaryText,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}


/// 浮层底部按钮：`filled` 为强调色实心「确定」，否则描边「重置」。
class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });
  final String label;
  final bool filled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? palette.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: filled ? null : Border.all(color: palette.accent, width: 1.4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: filled ? Colors.white : palette.accent,
          ),
        ),
      ),
    );
  }
}

/// 「轻量筛选」浮层。题材走服务端（综合隐藏），状态·篇幅·排序本地做。
/// 打开时回显 feed 现有选择，「确定」一次性套用，「重置」清空选择（不立即关）。
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.tab, required this.feed});
  final LibraryTab tab;
  final LibraryFeed feed;
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _theme = widget.feed.theme;
  late LibraryStatus _status = widget.feed.status;
  late bool _withinSixty = widget.feed.withinSixty;
  late LibrarySort _sort = widget.feed.sort;

  static const List<(LibrarySort, String)> _sortOptions = <(LibrarySort, String)>[
    (LibrarySort.none, '默认'),
    (LibrarySort.latest, '最新上线'),
    (LibrarySort.heat, '热度'),
    (LibrarySort.views, '播放量'),
    (LibrarySort.title, '剧名'),
    (LibrarySort.fewestEpisodes, '集数少优先'),
  ];

  void _reset() => setState(() {
        _theme = null;
        _status = LibraryStatus.any;
        _withinSixty = false;
        _sort = LibrarySort.none;
      });

  Future<void> _confirm() async {
    // 本地条件先套（同步、无网络）；题材走服务端放最后——没变时 setTheme 自己短路。
    widget.feed.applyLocalFilters(
      status: _status,
      withinSixty: _withinSixty,
      sort: _sort,
    );
    final navigator = Navigator.of(context);
    await widget.feed.setTheme(_theme);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final themes = themesForWebRoute(widget.tab.webRoute);
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: palette.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Text(
                  '轻量筛选',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: palette.primaryText,
                  ),
                ),
                const Spacer(),
                Pressable(
                  onTap: () => Navigator.of(context).pop(),
                  semanticLabel: '关闭',
                  child: Icon(Icons.close, color: palette.secondaryText),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (themes.isNotEmpty) ...[
              const _SheetLabel('题材'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final theme in themes)
                    _SheetChip(
                      label: theme.name,
                      selected: _theme == theme.id,
                      onTap: () => setState(
                        () => _theme = _theme == theme.id ? null : theme.id,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],
            const _SheetLabel('状态 / 篇幅'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _SheetChip(
                  label: '连载中',
                  selected: _status == LibraryStatus.ongoing,
                  onTap: () => setState(() => _status =
                      _status == LibraryStatus.ongoing
                          ? LibraryStatus.any
                          : LibraryStatus.ongoing),
                ),
                _SheetChip(
                  label: '已完结',
                  selected: _status == LibraryStatus.finished,
                  onTap: () => setState(() => _status =
                      _status == LibraryStatus.finished
                          ? LibraryStatus.any
                          : LibraryStatus.finished),
                ),
                _SheetChip(
                  label: '60 集内',
                  selected: _withinSixty,
                  onTap: () => setState(() => _withinSixty = !_withinSixty),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const _SheetLabel('排序'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final option in _sortOptions)
                  _SheetChip(
                    label: option.$2,
                    selected: _sort == option.$1,
                    onTap: () => setState(() => _sort = option.$1),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '按已加载短剧排序，缺少数据的短剧排在最后',
              style: TextStyle(fontSize: 12, color: palette.secondaryText),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(label: '重置', filled: false, onTap: _reset),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _SheetButton(label: '确定', filled: true, onTap: _confirm),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

