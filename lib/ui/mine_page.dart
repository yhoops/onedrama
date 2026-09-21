import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/database.dart';
import '../data/providers.dart';
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 我的：收藏 / 历史。
///
/// 历史是**从观看进度派生的**（`CONTEXT.md`：Watch History derived from Watch
/// Progress），所以这里没有「写历史」这回事——播放页写进度，这里只读。
class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key});

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesProvider);
    final history = ref.watch(historyProvider);
    final palette = OneDramaColors.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OneDramaSizes.pagePadding,
                10,
                0,
                12,
              ),
              child: Text(
                '我的',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: palette.primaryText,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OneDramaSizes.pagePadding,
              ),
              child: _Segmented(
                index: _tab,
                onChanged: (index) => setState(() => _tab = index),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _tab == 0
                  ? _FavoritesTab(favorites: favorites)
                  : _HistoryTab(history: history),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收藏 / 历史的分段控件。参考页是浅灰槽 + 白色胶囊选中态。
class _Segmented extends StatelessWidget {
  const _Segmented({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const List<String> _labels = <String>['收藏', '历史'];

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.field,
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxWidth / _labels.length;
          return Stack(
            children: [
              // 选中胶囊。用位移动画，切 tab 时滑过去而不是跳过去。
              AnimatedAlign(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: index == 0
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: Container(
                  width: slot,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < _labels.length; i++)
                    Expanded(
                      child: Pressable(
                        behavior: HitTestBehavior.opaque,
                        scale: 0.92,
                        onTap: () => onChanged(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: i == index
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == index
                                  ? palette.primaryText
                                  : palette.secondaryText,
                            ),
                            child: Text(_labels[i]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FavoritesTab extends ConsumerWidget {
  const _FavoritesTab({required this.favorites});

  final AsyncValue<List<FavoriteEntry>> favorites;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OneDramaColors.of(context);
    return favorites.when(
      loading: () => Center(
        child: CircularProgressIndicator(
          color: palette.accent,
          strokeWidth: 2.5,
        ),
      ),
      error: (error, stack) => _EmptyState(
        icon: Icons.error_outline,
        title: '读不出来',
        subtitle: '$error',
      ),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyState(
            icon: Icons.favorite_border,
            title: '把喜欢的故事留在这里',
            subtitle: '收藏短剧，下次打开就能接着看',
            action: '去发现短剧',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            OneDramaSizes.pagePadding,
            4,
            OneDramaSizes.pagePadding,
            24,
          ),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final entry = items[index];
            return _DramaRow(
              drama: entry.drama,
              subtitle: _subtitleOf(entry.drama),
              trailing: _relativeTime(entry.addedAt),
              // 收藏与历史不会同时在树里（`_tab == 0 ? ... : ...`），所以共用
              // 一个作用域就够，不会撞标签。
              heroTag: coverHeroTag('mine', entry.drama.id),
            );
          },
        );
      },
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.history});

  final AsyncValue<List<HistoryEntry>> history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OneDramaColors.of(context);
    return history.when(
      loading: () => Center(
        child: CircularProgressIndicator(
          color: palette.accent,
          strokeWidth: 2.5,
        ),
      ),
      error: (error, stack) => _EmptyState(
        icon: Icons.error_outline,
        title: '读不出来',
        subtitle: '$error',
      ),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyState(
            icon: Icons.history,
            title: '还没有观看记录',
            subtitle: '看过的剧会自动出现在这里',
            action: '去发现短剧',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            OneDramaSizes.pagePadding,
            4,
            OneDramaSizes.pagePadding,
            24,
          ),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final entry = items[index];
            return _DramaRow(
              drama: entry.drama,
              subtitle: '看到第 ${entry.episodeNumber} 集',
              trailing: _relativeTime(entry.updatedAt),
              progress: entry.ratio,
              heroTag: coverHeroTag('mine', entry.drama.id),
            );
          },
        );
      },
    );
  }
}

/// 一行：海报缩略 + 标题 + 副标题 + 右侧时间（+ 可选进度条）。
class _DramaRow extends StatelessWidget {
  const _DramaRow({
    required this.drama,
    required this.subtitle,
    required this.trailing,
    required this.heroTag,
    this.progress,
  });

  final Drama drama;
  final String subtitle;
  final String trailing;

  /// 封面的 Hero 标签。两端一致才会飞（见 [coverHeroTag]）。
  final String heroTag;

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Pressable(
      onTap: () => openDrama(context, drama, heroTag: heroTag),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 62,
              height: 82,
              child: Hero(
                tag: heroTag,
                child: DramaCover(
                  url: drama.cover,
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
                const SizedBox(height: 2),
                Text(
                  drama.displayTitle,
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
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.secondaryText,
                  ),
                ),
                if (progress != null && progress! > 0) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: palette.field,
                      valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              trailing,
              style: TextStyle(fontSize: 11.5, color: palette.secondaryText),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OneDramaColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: palette.field,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                icon,
                size: 42,
                color: palette.secondaryText.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: palette.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: palette.secondaryText),
            ),
            if (action != null) ...[
              const SizedBox(height: 22),
              FilledButton(
                // go 而不是 push：回到底栏外壳的根，切到短剧库那个分支。
                onPressed: () => context.go('/'),
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 12,
                  ),
                ),
                child: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _subtitleOf(Drama drama) {
  final parts = <String>[
    if (drama.episodeCount.isNotEmpty) '${drama.episodeCount}集',
    if (drama.totalEpisode.isNotEmpty && drama.episodeCount.isEmpty)
      '${drama.totalEpisode}集',
    if (drama.categoryName.isNotEmpty) drama.categoryName,
  ];
  return parts.isEmpty ? drama.remark : parts.join(' · ');
}

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${time.month}月${time.day}日';
}
