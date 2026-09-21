import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import 'database.dart';
import 'library_importer.dart';
import 'network.dart';
import 'ranking_cache.dart';
import 'search_history.dart';
import 'settings.dart';

/// 去重 + TTL 缓存拦截器。单独暴露是为了设置页能清缓存、也能读诊断计数。
final cacheInterceptorProvider = Provider<CoalescingCacheInterceptor>(
  (ref) => CoalescingCacheInterceptor(),
);

/// 全局 dio。协议包与封面图共用它，这样去重与 TTL 对两边都生效。
final dioProvider = Provider<Dio>(
  (ref) => buildAppDio(ref.watch(cacheInterceptorProvider)),
);

/// 设置与设备号。
///
/// 启动时 `await SettingsStore.open()` 再 override 进来——设备号必须在第一个请求
/// **之前**就位，所以不能偷懒做成异步 provider。
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) =>
      throw UnimplementedError('必须在 runApp 前 override settingsStoreProvider'),
);

/// 红果协议客户端。
///
/// 设备号从 [settingsStoreProvider] 注入——不注入的话每次启动都换一套，服务端风控
/// 会变脏（README 特意提醒过）。
final hongguoClientProvider = Provider<HongguoClient>((ref) {
  final store = ref.watch(settingsStoreProvider);
  return HongguoClient(http: ref.watch(dioProvider))
    ..deviceId = store.deviceId()
    ..installId = store.installId();
});

/// 本地数据库。在 `runApp` 前打开并 override 进来——建库是异步的，而页面不该为此
/// 各自处理一次「还没打开」。
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('必须在 runApp 前 override databaseProvider'),
);

/// 当前设置。改动立刻落盘。
class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsStoreProvider).settings();

  Future<void> update(AppSettings Function(AppSettings) change) async {
    final next = change(state);
    state = next;
    await ref.read(settingsStoreProvider).saveSettings(next);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 收藏列表。
final favoritesProvider = FutureProvider<List<FavoriteEntry>>(
  (ref) => ref.watch(databaseProvider).favoriteList(),
);

/// 历史列表（从观看进度派生）。
final historyProvider = FutureProvider<List<HistoryEntry>>(
  (ref) => ref.watch(databaseProvider).history(),
);

/// 某部剧是否已收藏。
final isFavoriteProvider = FutureProvider.family<bool, String>(
  (ref, dramaId) => ref.watch(databaseProvider).isFavorite(dramaId),
);

/// 某部剧的续播点：最后看的那一集。
final resumePointProvider = FutureProvider.family<ResumePoint?, String>(
  (ref, dramaId) => ref.watch(databaseProvider).resumePoint(dramaId),
);

/// 详情 + 分集。
final detailProvider = FutureProvider.family<DramaDetail, String>(
  (ref, seriesId) => ref.watch(hongguoClientProvider).fetchDetail(seriesId),
);

/// 网页详情的社交数据——**评分只在这里有**。
///
/// 单开一个 provider 是为了「渐进」：详情页主体（封面 / 标题 / 选集）不依赖它，评分到了
/// 再补上。网页约 290 KB，但 `/detail` 在 TTL 缓存白名单里，同一部剧短时间内只拉一次。
final webSocialProvider = FutureProvider.family<SocialInfo, String>(
  (ref, seriesId) =>
      ref.watch(hongguoClientProvider).fetchWebSocialInfo(seriesId),
);

/// 榜单的「上次成功结果」。落盘，所以冷启动也能立刻显示上次的榜单。
final rankingCacheProvider = Provider<RankingCache>(
  (ref) => RankingCache(ref.watch(settingsStoreProvider).prefs),
);

/// 搜索历史（搜过的词）。改动立刻落盘。
///
/// 顺序即「最近在前」，UI 直接用 [state]。见 `docs/plan.md` 阶段 5a。
class SearchHistoryNotifier extends Notifier<List<String>> {
  @override
  List<String> build() =>
      SearchHistoryStore(ref.watch(settingsStoreProvider).prefs).entries();

  SearchHistoryStore get _store =>
      SearchHistoryStore(ref.read(settingsStoreProvider).prefs);

  Future<void> remember(String keyword) async {
    final next = pushSearchKeyword(state, keyword);
    state = next;
    await _store.save(next);
  }

  Future<void> remove(String keyword) async {
    final next = state.where((item) => item != keyword).toList();
    state = next;
    await _store.save(next);
  }

  Future<void> clear() async {
    state = const <String>[];
    await _store.clear();
  }
}

final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

/// 剧库导入：每次启动自动跑一遍，设置「剧库与存储 → 更新剧库」手动再跑一次。
///
/// 它是**单例**（Provider 按容器缓存），内部还会把并发的两轮合成一轮——见
/// [LibraryImporter.run]。见 `docs/adr/0008`。
final libraryImporterProvider = Provider<LibraryImporter>(
  (ref) => LibraryImporter(
    client: ref.watch(hongguoClientProvider),
    database: ref.watch(databaseProvider),
    prefs: ref.watch(settingsStoreProvider).prefs,
  ),
);

/// 搜索联想（最多 10 条）。
final suggestionsProvider = FutureProvider.family<List<Suggestion>, String>(
  (ref, keyword) => ref.watch(hongguoClientProvider).searchSuggestions(keyword),
);
