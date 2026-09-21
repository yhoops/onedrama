import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/providers.dart';
import 'library_page.dart' show libraryTopics;
import 'theme.dart';
import 'widgets/drama_card.dart';
import 'widgets/pressable.dart';

/// 搜索页：边打边出联想，提交后走「网页搜索 ∪ 剧名联想」。
///
/// 首页的题材 chip 也是跳到这里（chip 是快捷搜索词，不是筛选器——红果没有题材词表
/// 接口，见 `docs/plan.md`）。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialKeyword = ''});

  final String initialKeyword;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialKeyword,
  );
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  List<Suggestion> _suggestions = const <Suggestion>[];
  bool _loadingSuggestions = false;

  SearchResult? _result;
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialKeyword.isNotEmpty) {
      // 从首页题材 chip 跳过来的：**不进历史**。chip 是浏览快捷方式（代码注释里就写了
      // 它是快捷搜索词而不是筛选器），首页有 10 个，随手点几个就把历史刷满了。见 5a。
      _runSearch(widget.initialKeyword, record: false);
    } else {
      // 没有初始词就让键盘直接起来——搜索页的唯一目的就是输入。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 打字时防抖 300ms 再拉联想，不然每个字符都打一次接口。
  void _onChanged(String value) {
    _debounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      setState(() {
        _suggestions = const <Suggestion>[];
        _result = null;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _loadingSuggestions = true);
      try {
        final items = await ref
            .read(hongguoClientProvider)
            .searchSuggestions(keyword);
        if (!mounted || _input.text.trim() != keyword) return;
        setState(() {
          _suggestions = items;
          _loadingSuggestions = false;
        });
      } catch (_) {
        // 联想挂掉不影响搜索本身，静默即可。
        if (mounted) setState(() => _loadingSuggestions = false);
      }
    });
  }

  /// 跑一次搜索。
  ///
  /// [record] 为假表示这次搜索**不进历史**——只有从首页题材 chip 跳过来的那一次是这样。
  /// 手打回车、点联想项、点历史词与热门词都算：那都是「在这个页面里主动搜的词」。
  Future<void> _runSearch(String raw, {bool record = true}) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) return;
    _debounce?.cancel();
    _focus.unfocus();
    if (_input.text != keyword) _input.text = keyword;
    if (record) {
      unawaited(ref.read(searchHistoryProvider.notifier).remember(keyword));
    }

    setState(() {
      _searching = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await ref.read(hongguoClientProvider).search(keyword);
      if (!mounted) return;
      setState(() {
        _result = result;
        _searching = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = '$failure';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            color: palette.field,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.search, size: 19, color: palette.secondaryText),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: _runSearch,
                  style: const TextStyle(fontSize: 14.5),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '搜索剧名、题材或标签',
                    hintStyle: TextStyle(
                      fontSize: 14.5,
                      color: palette.secondaryText,
                    ),
                  ),
                ),
              ),
              if (_input.text.isNotEmpty)
                IconButton(
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _input.clear();
                    _onChanged('');
                    _focus.requestFocus();
                  },
                  icon: Icon(Icons.cancel, color: palette.secondaryText),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: Text('取消', style: TextStyle(color: palette.primaryText)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final palette = OneDramaColors.of(context);
    if (_searching) {
      return Center(
        child: CircularProgressIndicator(
          color: palette.accent,
          strokeWidth: 2.5,
        ),
      );
    }
    if (_error != null) {
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
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: palette.secondaryText,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _runSearch(_input.text),
              style: FilledButton.styleFrom(backgroundColor: palette.accent),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    final result = _result;
    if (result != null) {
      if (result.dramas.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              '没找到相关的剧，换个词试试',
              style: TextStyle(fontSize: 13, color: palette.secondaryText),
            ),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          OneDramaSizes.pagePadding,
          12,
          OneDramaSizes.pagePadding,
          24,
        ),
        itemCount: result.dramas.length + 1,
        separatorBuilder: (context, index) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Row(
              children: [
                Text(
                  '找到 ${result.total} 部',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.secondaryText,
                  ),
                ),
                if (result.limited) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.warning.isEmpty ? '结果可能不全' : result.warning,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.secondaryText,
                      ),
                    ),
                  ),
                ],
              ],
            );
          }
          final drama = result.dramas[index - 1];
          return _ResultRow(
            drama: drama,
            heroTag: coverHeroTag('search', drama.id),
          );
        },
      );
    }

    // 还没提交：显示联想，或者没输入时的热门词。
    if (_suggestions.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.only(top: 4),
        itemCount: _suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          return ListTile(
            leading: Icon(Icons.search, size: 18, color: palette.secondaryText),
            title: Text(
              suggestion.name,
              style: const TextStyle(fontSize: 14.5),
            ),
            trailing: suggestion.type.isEmpty
                ? null
                : Text(
                    _typeLabel(suggestion.type),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: palette.secondaryText,
                    ),
                  ),
            onTap: () => _runSearch(suggestion.name),
          );
        },
      );
    }

    if (_loadingSuggestions) {
      return const SizedBox.shrink();
    }

    // 还没提交、也没有联想：**最近搜索在上、热门搜索在下**。
    // 历史最多 20 条，长了要能滚，所以整块放进 ListView。
    final history = ref.watch(searchHistoryProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OneDramaSizes.pagePadding,
        16,
        OneDramaSizes.pagePadding,
        24,
      ),
      children: [
        if (history.isNotEmpty) ...[
          _BlockHead(
            title: '最近搜索',
            action: '清空',
            onAction: () => ref.read(searchHistoryProvider.notifier).clear(),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final keyword in history)
                _KeywordChip(
                  label: keyword,
                  onTap: () => _runSearch(keyword),
                  // 长按删单条。**没有可见的删除键**是刻意的：参考图里没有搜索页
                  // （`参考的前端页面/` 六张都没有），这一屏是自由设计，删除压在长按上、
                  // 整块清空交给标题右侧那个「清空」。删错了有撤销。
                  onLongPress: () => _forget(keyword),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        const _BlockHead(title: '热门搜索'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final topic in libraryTopics)
              _KeywordChip(label: topic, onTap: () => _runSearch(topic)),
          ],
        ),
      ],
    );
  }

  /// 删一条历史。给一次撤销——长按是误触重灾区，而这一条删了就找不回来了。
  void _forget(String keyword) {
    ref.read(searchHistoryProvider.notifier).remove(keyword);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除「$keyword」'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '撤销',
            onPressed: () =>
                ref.read(searchHistoryProvider.notifier).remember(keyword),
          ),
        ),
      );
  }

  static String _typeLabel(String type) => switch (type) {
    'short_play_name' => '短剧',
    'actor_name' || 'short_play_actor' => '演员',
    'common_query' || 'short_play_category' => '分类',
    _ => '',
  };
}

/// 一块的标题行：左边标题，右边可选的整块动作（现在只有「清空」用）。
class _BlockHead extends StatelessWidget {
  const _BlockHead({required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    final action = this.action;
    final onAction = this.onAction;
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: palette.secondaryText,
          ),
        ),
        const Spacer(),
        if (action != null && onAction != null)
          Pressable(
            onTap: onAction,
            scale: 0.94,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 15,
                    color: palette.secondaryText,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    action,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 一个词的小 chip。「最近搜索」与「热门搜索」共用，样式跟着首页的题材 chip 走。
class _KeywordChip extends StatelessWidget {
  const _KeywordChip({
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: palette.field,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13.5, color: palette.primaryText),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.drama, required this.heroTag});

  final Drama drama;

  /// 封面的 Hero 标签。两端一致才会飞（见 [coverHeroTag]）。
  final String heroTag;

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
              width: 68,
              height: 90,
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
                    fontSize: 15.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: palette.primaryText,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _subtitle(drama),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: palette.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _subtitle(Drama drama) {
    final parts = <String>[
      if (drama.episodeCount.isNotEmpty) '${drama.episodeCount}集',
      if (drama.totalEpisode.isNotEmpty && drama.episodeCount.isEmpty)
        '${drama.totalEpisode}集',
      if (drama.categoryName.isNotEmpty) drama.categoryName,
      if (drama.releaseStatus == 'finished') '已完结',
      if (drama.releaseStatus == 'ongoing') '连载中',
    ];
    final head = parts.join(' · ');
    final intro = drama.intro.isNotEmpty ? drama.intro : drama.desc;
    if (intro.isEmpty) return head;
    return head.isEmpty ? intro : '$head\n$intro';
  }
}
