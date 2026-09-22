import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cover_cache.dart';
import '../data/library_importer.dart';
import '../data/media_cache.dart';
import '../data/providers.dart';
import '../data/settings.dart';
import 'theme.dart';

/// 设置。分组与参考页一致：主题 / 播放 / 播放·手势与控制 / 剧库与存储。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final palette = OneDramaColors.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OneDramaSizes.pagePadding,
                10,
                0,
                4,
              ),
              child: Text(
                '设置',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: palette.primaryText,
                ),
              ),
            ),
            _Section(
              title: '主题',
              children: [
                _PickerRow<ThemePreference>(
                  icon: Icons.dark_mode_outlined,
                  label: '外观',
                  value: settings.theme,
                  display: _themeName,
                  options: const [
                    (ThemePreference.system, '跟随系统'),
                    (ThemePreference.light, '浅色'),
                    (ThemePreference.dark, '深色'),
                  ],
                  onPick: (value) =>
                      notifier.update((s) => s.copyWith(theme: value)),
                ),
                _SwitchRow(
                  icon: Icons.text_fields,
                  label: '大字模式',
                  value: settings.largeText,
                  onChanged: (value) =>
                      notifier.update((s) => s.copyWith(largeText: value)),
                ),
              ],
            ),
            _Section(
              title: '播放',
              children: [
                _PickerRow<double>(
                  icon: Icons.speed_outlined,
                  label: '默认倍速',
                  value: settings.defaultSpeed,
                  display: (value) => '${value}x',
                  options: const [
                    (0.75, '0.75x'),
                    (1.0, '1.0x'),
                    (1.25, '1.25x'),
                    (1.5, '1.5x'),
                    (2.0, '2.0x'),
                  ],
                  onPick: (value) =>
                      notifier.update((s) => s.copyWith(defaultSpeed: value)),
                ),
                _PickerRow<int>(
                  icon: Icons.high_quality_outlined,
                  label: '优先画质',
                  value: settings.preferredQuality,
                  display: (value) => value == 0 ? '自动' : '${value}P',
                  options: const [(0, '自动'), (720, '720P'), (1080, '1080P')],
                  onPick: (value) => notifier.update(
                    (s) => s.copyWith(preferredQuality: value),
                  ),
                ),
                _SwitchRow(
                  icon: Icons.skip_next_outlined,
                  label: '自动播放下一集',
                  value: settings.autoPlayNext,
                  onChanged: (value) =>
                      notifier.update((s) => s.copyWith(autoPlayNext: value)),
                ),
                // 与「自动播放下一集」**解耦**：关掉连播仍然预取——用户可能自己点下一集。
                // 关掉它则预取完全不发生，见 docs/adr/0009。
                _SwitchRow(
                  icon: Icons.download_for_offline_outlined,
                  label: '预缓存下一集',
                  value: settings.prefetchNext,
                  onChanged: (value) =>
                      notifier.update((s) => s.copyWith(prefetchNext: value)),
                ),
                _SwitchRow(
                  icon: Icons.history_toggle_off,
                  label: '记忆播放进度',
                  value: settings.rememberProgress,
                  onChanged: (value) => notifier.update(
                    (s) => s.copyWith(rememberProgress: value),
                  ),
                ),
              ],
            ),
            _Section(
              title: '播放 · 手势与控制',
              children: [
                _PickerRow<ControlSide>(
                  icon: Icons.vertical_align_center,
                  label: '控制栏位置',
                  value: settings.controlSide,
                  display: (value) => value == ControlSide.left ? '左侧' : '右侧',
                  options: const [
                    (ControlSide.right, '右侧'),
                    (ControlSide.left, '左侧'),
                  ],
                  onPick: (value) =>
                      notifier.update((s) => s.copyWith(controlSide: value)),
                ),
                _PickerRow<GestureSensitivity>(
                  icon: Icons.tune,
                  label: '手势灵敏度',
                  value: settings.gestureSensitivity,
                  display: (value) => switch (value) {
                    GestureSensitivity.low => '低',
                    GestureSensitivity.medium => '中',
                    GestureSensitivity.high => '高',
                  },
                  options: const [
                    (GestureSensitivity.low, '低'),
                    (GestureSensitivity.medium, '中'),
                    (GestureSensitivity.high, '高'),
                  ],
                  onPick: (value) => notifier.update(
                    (s) => s.copyWith(gestureSensitivity: value),
                  ),
                ),
                _SwitchRow(
                  icon: Icons.vibration,
                  label: '触感反馈',
                  value: settings.hapticFeedback,
                  onChanged: (value) =>
                      notifier.update((s) => s.copyWith(hapticFeedback: value)),
                ),
              ],
            ),
            const _StorageSection(),
          ],
        ),
      ),
    );
  }

  static String _themeName(ThemePreference value) => switch (value) {
    ThemePreference.system => '跟随系统',
    ThemePreference.light => '浅色',
    ThemePreference.dark => '深色',
  };
}

/// 分组：一个标题 + 一张白卡片。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            OneDramaSizes.pagePadding + 4,
            20,
            0,
            8,
          ),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.secondaryText,
            ),
          ),
        ),
        // 必须是 Material，不能是 Container：里面的 `_RowShell` 用的是 InkWell，水波纹
        // 要有个 Material 祖先才画得出来。用不透明 `Container` 时，波纹会画到 Scaffold
        // 的 ink 层上、再被这层不透明底色整个盖住——十行设置项点了完全没反应，就是这个
        // 原因（见 docs/plan.md 阶段 4）。
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OneDramaSizes.pagePadding,
          ),
          child: Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(OneDramaSizes.cardRadius),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 52),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: palette.divider,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.icon,
    required this.label,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = OneDramaColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OneDramaSizes.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: palette.secondaryText),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: text.bodyMedium?.copyWith(
                  fontSize: 15,
                  color: palette.primaryText,
                ),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _RowShell(
    icon: icon,
    label: label,
    trailing: Switch.adaptive(
      value: value,
      activeThumbColor: Colors.white,
      activeTrackColor: OneDramaColors.of(context).accent,
      onChanged: onChanged,
    ),
  );
}

/// 一行「标签 + 当前值 > 」，点了弹选择面板。
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.display,
    required this.options,
    required this.onPick,
  });

  final IconData icon;
  final String label;
  final T value;
  final String Function(T) display;
  final List<(T, String)> options;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return _RowShell(
      icon: icon,
      label: label,
      onTap: () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          backgroundColor: palette.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: palette.primaryText,
                    ),
                  ),
                ),
                for (final option in options)
                  ListTile(
                    title: Text(option.$2),
                    trailing: option.$1 == value
                        ? Icon(Icons.check, size: 20, color: palette.accent)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(option.$1),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
        if (picked != null) onPick(picked);
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            display(value),
            style: TextStyle(fontSize: 14, color: palette.secondaryText),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: palette.secondaryText),
        ],
      ),
    );
  }
}

/// 存储与清理。缓存占用是异步读的，所以这一段自带状态。
class _StorageSection extends ConsumerStatefulWidget {
  const _StorageSection();

  @override
  ConsumerState<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<_StorageSection> {
  ({int files, int bytes})? _usage;

  /// 封面磁盘缓存的占用。和剧集缓存一起显示在同一行右侧——那个数字得能回答
  /// 「按下去会腾出多少」，而这一行清的就是这两样。
  int _coverBytes = 0;

  /// 上次导入剧库的时间。异步读的，所以和上面两个一起放进状态。
  DateTime? _importedAt;

  /// 剧库部数：分类标签快照里不同剧 ID 的数量。见 `CONTEXT.md` 的 Library Count。
  int _libraryCount = 0;

  /// 抓住导入器本身而不是每次 `ref.read`——dispose 里要用它摘监听，
  /// 而那时候已经不该碰 `ref` 了。
  LibraryImporter? _importer;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final importer = ref.read(libraryImporterProvider);
    _importer = importer;
    // 启动那一轮导入跑完时，这一行也得跟着变。
    //
    // 它的进度走同一个 notifier，所以「在跑」那一段是实时的；但跑完之后显示的部数与
    // 时间戳来自 `_refreshUsage()` 取的快照、**不是实时的**。用户正停在设置页时不给这
    // 一下，那一行会一直停在旧数字上——而启动那一轮恰恰是最常见的更新路径。
    importer.progress.addListener(_onImportProgress);
    _refreshUsage();
  }

  @override
  void dispose() {
    _importer?.progress.removeListener(_onImportProgress);
    super.dispose();
  }

  /// 导入从「在跑」变回「没在跑」＝这一轮结束了。
  void _onImportProgress() {
    if (_importer?.progress.value != null) return;
    unawaited(_refreshUsage());
  }

  Future<void> _refreshUsage() async {
    // `ref` 一律在第一个 await 之前取完：中间任何一个 await 都可能跨过 dispose。
    final database = ref.read(databaseProvider);
    final usage = await episodeCacheUsage();
    final covers = await coverCacheSize();
    final count = await database.libraryCount();
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _coverBytes = covers;
      _libraryCount = count;
      _importedAt = _importer?.lastImportedAt();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _toast('失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 手动跑一遍剧库导入。启动时已经自动跑过一次，这里是「我就要现在更新」。
  ///
  /// 文案交给 [importToast]：首次导入不弹（那时「新增」就是全部），部分失败要点明。
  /// **只有这一轮弹** —— 启动那一轮跑完是静默的，一进 App 就冒东西出来太吵。
  Future<void> _importLibrary() async {
    final report = await ref.read(libraryImporterProvider).run();
    await _refreshUsage();
    if (!mounted) return;
    final message = importToast(report, libraryCount: _libraryCount);
    if (message != null) _toast(message);
  }

  /// 那一行右侧的静态文案：「267 部 · 3 分钟前」/「尚未更新」。
  ///
  /// 部数占了原来时间戳的位置，但**时间戳没丢**：快照每次启动都重写，平时它几乎总是
  /// 「刚刚」；只有导入连续失败时才会停在两天前，而那正是最需要知道的时候。
  String _libraryLabel() {
    if (_libraryCount == 0) return '尚未更新';
    final at = _importedAt;
    return at == null
        ? '$_libraryCount 部'
        : '$_libraryCount 部 · ${_relativeTime(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    final database = ref.read(databaseProvider);
    final palette = OneDramaColors.of(context);

    return _Section(
      title: '剧库与存储',
      children: [
        _RowShell(
          icon: Icons.library_add_outlined,
          label: '更新剧库',
          onTap: _busy ? null : () => _run(_importLibrary),
          // 在跑就显示进度，跑完显示「267 部 · 3 分钟前」。启动时那一轮也会走到这里——
          // 进度走 ValueNotifier，所以两条路径都能看见同一份状态；而跑完之后要刷新
          // 部数与时间戳，靠的是 `_onImportProgress` 那个监听。
          trailing: ValueListenableBuilder<LibraryImportProgress?>(
            valueListenable: ref.read(libraryImporterProvider).progress,
            builder: (context, progress, _) => Text(
              progress?.label ?? _libraryLabel(),
              style: TextStyle(fontSize: 14, color: palette.secondaryText),
            ),
          ),
        ),
        _RowShell(
          icon: Icons.cleaning_services_outlined,
          label: '清除缓存',
          onTap: _busy
              ? null
              : () => _run(() async {
                  final result = await clearEpisodeCache();
                  ref.read(cacheInterceptorProvider).clear();
                  // 榜单缓存也是「可重建的本地副本」，清缓存就该一起清掉；
                  // 否则清完之后进榜单页还显示着旧榜，名不副实。
                  final boards = await ref.read(rankingCacheProvider).clear();
                  // 封面同理，而且它有两层：磁盘那份与内存那份，见 clearCoverCaches。
                  final covers = await clearCoverCaches();
                  // 剧库快照同属这一类。顺手把时间戳也忘掉——快照都没了，设置页再显示
                  // 「刚刚更新」就是骗人。
                  final library = await database.clearLibrary();
                  await ref.read(libraryImporterProvider).forgetImportedAt();
                  await _refreshUsage();
                  _toast(
                    '已清除 ${result.files} 个剧集缓存'
                    '（${formatBytes(result.bytes)}）'
                    '${boards > 0 ? '，榜单缓存已重置' : ''}'
                    '${library > 0 ? '，剧库快照 $library 条' : ''}'
                    '，封面缓存 ${formatBytes(covers)}',
                  );
                }),
          trailing: Text(
            usage == null
                ? '统计中…'
                : '剧集 ${usage.files} 个 · '
                      '${formatBytes(usage.bytes + _coverBytes)}',
            style: TextStyle(fontSize: 14, color: palette.secondaryText),
          ),
        ),
        _RowShell(
          icon: Icons.history,
          label: '清空观看历史',
          onTap: _busy
              ? null
              : () => _run(() async {
                  await database.clearHistory();
                  ref.invalidate(historyProvider);
                  _toast('观看历史已清空');
                }),
          trailing: Icon(
            Icons.chevron_right,
            size: 20,
            color: palette.secondaryText,
          ),
        ),
        _RowShell(
          icon: Icons.favorite_border,
          label: '清空收藏',
          onTap: _busy
              ? null
              : () => _run(() async {
                  await database.clearFavorites();
                  ref.invalidate(favoritesProvider);
                  _toast('收藏已清空');
                }),
          trailing: Icon(
            Icons.chevron_right,
            size: 20,
            color: palette.secondaryText,
          ),
        ),
        // 搜索历史是**用户数据**（不是可重建的本地副本），所以它不归「清除缓存」管，
        // 自己占一行——与清空历史、清空收藏同一个道理。
        _RowShell(
          icon: Icons.manage_search_outlined,
          label: '清空搜索历史',
          onTap: _busy
              ? null
              : () => _run(() async {
                  await ref.read(searchHistoryProvider.notifier).clear();
                  _toast('搜索历史已清空');
                }),
          trailing: Icon(
            Icons.chevron_right,
            size: 20,
            color: palette.secondaryText,
          ),
        ),
        _RowShell(
          icon: Icons.fingerprint,
          label: '重新生成设备号',
          onTap: _busy
              ? null
              : () => _run(() async {
                  await ref.read(settingsStoreProvider).regenerateDevice();
                  // 客户端是建好时读的设备号，重建才会用上新的。
                  ref.invalidate(hongguoClientProvider);
                  _toast('设备号已重新生成，推荐列表会换一套');
                }),
          trailing: Icon(
            Icons.chevron_right,
            size: 20,
            color: palette.secondaryText,
          ),
        ),
      ],
    );
  }
}

/// 「3 分钟前」这种。`mine_page.dart` 里那份是私有的，这里就四行，不为了共用一个函数
/// 绕一圈——与 `library_page.dart` 里那份 `_clock` 同一个口径。
String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  return '${time.month}月${time.day}日';
}
