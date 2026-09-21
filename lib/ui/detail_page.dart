import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/providers.dart';
import 'format.dart';
import 'player_page.dart';
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 详情页：竖版沉浸式。
///
/// 参考页没给详情页，所以形态是定的：模糊封面背景 + 标题 / 评分 / 标签 / 总集数 +
/// 简介可展开 + 选集网格（超 30 集分页）+ 底部固定「继续观看 / 开始播放」。
class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({
    super.key,
    required this.seriesId,
    this.preview,
    this.heroTag,
  });

  final String seriesId;

  /// 从列表点进来时带的那份快照。有它就能**立刻**画出标题与封面，不必等详情请求——
  /// 首屏观感差别很大。
  final Drama? preview;

  /// 被点的那张卡上封面的 Hero 标签（见 `coverHeroTag`）。**两端一致**封面才会飞过来；
  /// 没有（深链直接进详情）就整页淡入，不画 Hero。
  final String? heroTag;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

/// 选集一页显示多少集。参考页的选集网格也是分批的。
const int episodesPerPage = 30;

class _DetailPageState extends ConsumerState<DetailPage> {
  final ScrollController _scroll = ScrollController();
  int _range = 0;
  bool _introExpanded = false;

  /// 0 = 完全展开，1 = 完全收起。用它驱动标题的淡入——展开时不显示标题，
  /// 否则深色标题压在模糊封面上根本看不清。
  double _collapse = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final next = (_scroll.offset / 200).clamp(0.0, 1.0);
    if ((next - _collapse).abs() < 0.02) return;
    setState(() => _collapse = next);
  }

  /// 评分的取值顺序：**网页详情优先**，`drama.score` 只作兜底。
  ///
  /// 顺序不能反。从榜单点进来时 `preview.score` 是榜单的 `scoreText`（`9.0`），而网页给的
  /// 是这部剧自己的 `9.2`——两者都是「评分」但可能不一致。先显示前者、等后者到了再换掉，
  /// 就是**同一个数字两个来源打架**，用户会看到数字跳一下。所以只认网页那一份；它给不出
  /// （约 40% 的剧没有评分）才退回已有的 `score`。
  ///
  /// App 详情接口根本没有评分（39 个字段里只有 `hot_score`），所以必须问网页。
  String _scoreText(Drama drama, SocialInfo? social) {
    if (social != null && social.hasRating) return scoreLabel('${social.rating}');
    if (drama.score.isNotEmpty) return scoreLabel(drama.score);
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(detailProvider(widget.seriesId));
    // 评分来自另一个接口，会晚于主体到达；这里不等它（见 webSocialProvider）。
    final social = ref.watch(webSocialProvider(widget.seriesId));
    final preview = widget.preview;
    final drama = detail.value?.drama ?? preview;

    return Scaffold(
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          _Header(
            seriesId: widget.seriesId,
            drama: drama,
            loading: detail.isLoading,
            collapse: _collapse,
            heroTag: widget.heroTag,
          ),
          if (drama != null) ...[
            SliverToBoxAdapter(
              child: _MetaRow(
                drama: drama,
                score: _scoreText(drama, social.value),
              ),
            ),
            if (drama.intro.isNotEmpty || drama.desc.isNotEmpty)
              SliverToBoxAdapter(
                child: _Intro(
                  text: drama.intro.isNotEmpty ? drama.intro : drama.desc,
                  expanded: _introExpanded,
                  onToggle: () =>
                      setState(() => _introExpanded = !_introExpanded),
                ),
              ),
          ],
          ..._episodesSection(detail),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
      bottomNavigationBar: drama == null
          ? null
          : _BottomBar(seriesId: widget.seriesId, drama: drama),
    );
  }

  List<Widget> _episodesSection(AsyncValue<DramaDetail> detail) {
    final palette = OneDramaColors.of(context);
    final episodes = detail.value?.episodes ?? const <Episode>[];
    if (detail.hasError && episodes.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Column(
                children: [
                  Text(
                    '${detail.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: () =>
                        ref.invalidate(detailProvider(widget.seriesId)),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.accent,
                    ),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }
    if (episodes.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          ),
        ),
      ];
    }

    final pageCount = (episodes.length / episodesPerPage).ceil();
    final start = _range * episodesPerPage;
    final end = (start + episodesPerPage).clamp(0, episodes.length);
    final visible = episodes.sublist(start, end);

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OneDramaSizes.pagePadding,
            20,
            OneDramaSizes.pagePadding,
            0,
          ),
          child: Row(
            children: [
              Text(
                '选集',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: palette.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '共 ${episodes.length} 集',
                style: TextStyle(fontSize: 12.5, color: palette.secondaryText),
              ),
            ],
          ),
        ),
      ),
      if (pageCount > 1)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: OneDramaSizes.pagePadding,
                vertical: 8,
              ),
              itemCount: pageCount,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final first = index * episodesPerPage + 1;
                final last = ((index + 1) * episodesPerPage).clamp(
                  0,
                  episodes.length,
                );
                final selected = index == _range;
                return Pressable(
                  onTap: () => setState(() => _range = index),
                  scale: 0.94,
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: selected ? palette.accentSoft : palette.field,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '$first-$last',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected ? palette.accent : palette.primaryText,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      _EpisodeGrid(
        seriesId: widget.seriesId,
        drama: detail.value!.drama,
        episodes: visible,
        allEpisodes: episodes,
      ),
    ];
  }
}

/// 头部：模糊封面铺底 + 渐变遮罩 + 海报 + 标题。
class _Header extends StatelessWidget {
  const _Header({
    required this.seriesId,
    required this.drama,
    required this.loading,
    required this.collapse,
    required this.heroTag,
  });

  final String seriesId;
  final Drama? drama;
  final bool loading;

  /// 0 = 展开，1 = 收起。
  final double collapse;

  /// 海报的 Hero 标签。见 [DetailPage.heroTag]。
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final cover = drama?.cover ?? '';
    final background = Theme.of(context).scaffoldBackgroundColor;
    return SliverAppBar(
      expandedHeight: 300,
      pinned: true,
      // 收起时才把底色补实，展开时透出模糊封面。
      backgroundColor: Color.lerp(Colors.transparent, background, collapse),
      surfaceTintColor: Colors.transparent,
      leading: _CircleButton(
        icon: Icons.arrow_back,
        onTap: () => context.pop(),
      ),
      // 标题只在接近收起时出现。展开状态下标题在图里（见下面的背景层）。
      title: Opacity(
        opacity: collapse,
        child: Text(
          drama?.displayTitle ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: palette.primaryText,
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.parallax,
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (cover.isNotEmpty)
              // 模糊封面铺底。sigma 大一点，免得边缘还能看出内容。
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Transform.scale(
                  scale: 1.15,
                  child: DramaCover(url: cover),
                ),
              )
            else
              ColoredBox(color: palette.field),
            // 从透明到页面底色的渐变，让下面的文字有落脚点。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: 0.35),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  OneDramaSizes.pagePadding,
                  0,
                  OneDramaSizes.pagePadding,
                  12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 104,
                      child: AspectRatio(
                        aspectRatio: OneDramaSizes.posterAspect,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            OneDramaSizes.posterRadius,
                          ),
                          child: _poster(palette, cover),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              drama?.displayTitle ?? (loading ? '加载中…' : ''),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                height: 1.25,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black45),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _statusLine(drama),
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: Colors.white70,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black45),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 海报。有 [heroTag] 就套 Hero——标签由列表页给，**两端一致**才飞得起来。
  ///
  /// 飞行外壳用 [coverFlightShuttle]（来源那一端的图）而不是默认的目的地端：
  /// 列表行只解到 [rowCoverWidth]，详情这张是 [gridCoverWidth]，两端不是同一个缓存键，
  /// 默认外壳那张没被预热过，飞行一开始会先出灰块。
  Widget _poster(OneDramaColors palette, String cover) {
    if (drama == null) return ColoredBox(color: palette.field);
    final image = DramaCover(url: cover);
    final tag = heroTag;
    if (tag == null) return image;
    return Hero(
      tag: tag,
      flightShuttleBuilder: coverFlightShuttle,
      child: image,
    );
  }

  static String _statusLine(Drama? drama) {
    if (drama == null) return '';
    final parts = <String>[
      if (drama.episodeCount.isNotEmpty) '全 ${drama.episodeCount} 集',
      if (drama.totalEpisode.isNotEmpty && drama.episodeCount.isEmpty)
        '全 ${drama.totalEpisode} 集',
      if (drama.categoryName.isNotEmpty) drama.categoryName,
      if (drama.releaseStatus == 'ongoing') '连载中',
      if (drama.releaseStatus == 'finished') '已完结',
    ];
    return parts.join(' · ');
  }
}

/// 评分 / 热度 / 观看 / 标签。
///
/// 顺序是 **评分 → 热度 → 观看**：评分放最前（一眼判断要不要看），与网页详情的排布一致
/// （那边是 `9.2分` 在前、`4203万热度` 在后）。评分晚到时插在最左，把另两个往右推。
class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.drama, required this.score});

  final Drama drama;

  /// 已格式化好的评分文本（如 `9.2分`）。空串表示这部剧没有评分。
  final String score;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final heat = heatLabel(drama.heat);
    final views = viewsLabel(drama.views);
    final chips = <Widget>[
      if (score.isNotEmpty) _MetaChip(icon: Icons.star_rounded, text: score),
      if (heat.isNotEmpty)
        _MetaChip(icon: Icons.local_fire_department_rounded, text: heat),
      if (views.isNotEmpty)
        _MetaChip(icon: Icons.play_circle_outline, text: views),
    ];
    final tags = drama.tags.take(6).toList();

    if (chips.isEmpty && tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        12,
        OneDramaSizes.pagePadding,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chips.isNotEmpty)
            Wrap(spacing: 14, runSpacing: 6, children: chips),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: palette.field,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.primaryText,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: palette.accent),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: palette.primaryText,
          ),
        ),
      ],
    );
  }
}

/// 简介。默认收三行，可展开。
class _Intro extends StatelessWidget {
  const _Intro({
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  final String text;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        16,
        OneDramaSizes.pagePadding,
        0,
      ),
      child: Pressable(
        onTap: onToggle,
        // 整块简介都是点击区（含「展开全部」那行），缩放只给一点点，别让它晃。
        scale: 0.99,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '简介',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: palette.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Text(
                text,
                maxLines: expanded ? null : 3,
                overflow: expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.6,
                  color: palette.secondaryText,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  expanded ? '收起' : '展开全部',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: palette.accent,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 选集网格。5 列，标出「看到第几集」。
class _EpisodeGrid extends ConsumerWidget {
  const _EpisodeGrid({
    required this.seriesId,
    required this.drama,
    required this.episodes,
    required this.allEpisodes,
  });

  final String seriesId;
  final Drama drama;
  final List<Episode> episodes;
  final List<Episode> allEpisodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OneDramaColors.of(context);
    final resume = ref.watch(resumePointProvider(drama.id)).value;
    final width = MediaQuery.sizeOf(context).width;
    final slot = (width - OneDramaSizes.pagePadding * 2 - 4 * 8) / 5;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        8,
        OneDramaSizes.pagePadding,
        0,
      ),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: slot / 40,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final episode = episodes[index];
          final watching = resume?.videoId == episode.videoId;
          return Pressable(
            onTap: () => openPlayer(
              context,
              drama: drama,
              episodes: allEpisodes,
              index: allEpisodes.indexWhere(
                (item) => item.videoId == episode.videoId,
              ),
            ),
            scale: 0.92,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: watching ? palette.accentSoft : palette.field,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${episode.number}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: watching ? FontWeight.w700 : FontWeight.w500,
                  color: watching ? palette.accent : palette.primaryText,
                ),
              ),
            ),
          );
        }, childCount: episodes.length),
      ),
    );
  }
}

/// 底部固定条：收藏 + 继续观看 / 开始播放。
class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.seriesId, required this.drama});

  final String seriesId;
  final Drama drama;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OneDramaColors.of(context);
    final detail = ref.watch(detailProvider(seriesId)).value;
    final episodes = detail?.episodes ?? const <Episode>[];
    final resume = ref.watch(resumePointProvider(drama.id)).value;
    final favorite = ref.watch(isFavoriteProvider(drama.id)).value ?? false;

    final resumeIndex = resume == null
        ? -1
        : episodes.indexWhere((item) => item.videoId == resume.videoId);
    final hasResume = resumeIndex >= 0;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            12,
            8,
            OneDramaSizes.pagePadding,
            8,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: favorite ? '取消收藏' : '收藏',
                onPressed: () async {
                  await ref
                      .read(databaseProvider)
                      .setFavorite(drama, !favorite);
                  ref.invalidate(isFavoriteProvider(drama.id));
                  ref.invalidate(favoritesProvider);
                },
                icon: Icon(
                  favorite ? Icons.favorite : Icons.favorite_border,
                  color: favorite ? palette.accent : palette.secondaryText,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: FilledButton(
                  onPressed: episodes.isEmpty
                      ? null
                      : () => openPlayer(
                          context,
                          drama: drama,
                          episodes: episodes,
                          index: hasResume ? resumeIndex : 0,
                          startAt: hasResume ? resume!.positionMs : 0,
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(23),
                    ),
                  ),
                  child: Text(
                    hasResume ? '继续观看 第 ${resume!.episodeNumber} 集' : '开始播放',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部左上角的圆形返回键。参考页的播放页也有同样的圆钮。
class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(6),
    child: Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          color: Color(0x66000000),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    ),
  );
}
