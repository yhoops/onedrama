import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database.dart';
import 'data/library_importer.dart';
import 'data/providers.dart';
import 'data/settings.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 两件必须在第一帧/第一个请求之前就位的事：设备号（否则每次启动换一套，风控会变脏）
  // 与本地库（建库是异步的，页面不该各自处理「还没打开」）。
  final settings = await SettingsStore.open();
  final database = await AppDatabase.open();
  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        databaseProvider.overrideWithValue(database),
      ],
      child: const OneDramaApp(),
    ),
  );
}

class OneDramaApp extends ConsumerStatefulWidget {
  const OneDramaApp({super.key});

  @override
  ConsumerState<OneDramaApp> createState() => _OneDramaAppState();
}

class _OneDramaAppState extends ConsumerState<OneDramaApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 首次进入 App 自动导一轮剧库；之后只在设置里手动点「更新剧库」（`docs/adr/0012`）。
      //
      // 原来的口径是**每次启动**都导（ADR-0008），但那要打 20 次签名请求、下 350 多张
      // 封面——启动时白花的代价太大，而且短时间内反复启动会被上游风控限住（实测连跑
      // 四轮之后整轮导入被拒过一次）。改成「只跑一次 + 手动触发」之后，设置页那一行的
      // 时间戳就成了「这份数据多旧」的**唯一**指示器，所以它必须留着。
      final importer = ref.read(libraryImporterProvider);
      final primed = importer.startupImportDone();
      // 取证痕迹：跳过时打一行，否则「为什么这次启动没导入」只能靠猜。同 `[warm]` 那套。
      if (primed) debugPrint('[library] 首次导入已跑过，跳过自动更新');
      if (!primed) unawaited(_importLibraryOnce(importer));
      // 榜单预热。走 web 主机（免签名），与剧库导入走的 app 主机不是同一路，不抢接口——
      // 它让「第一次进榜单」不用等网络。见 `data/ranking_warmer.dart`。
      unawaited(ref.read(rankingWarmerProvider).run());
    });
  }

  /// 首次进入 App 那一轮剧库导入。
  ///
  /// **先置位再跑**：失败也算跑过（见 [LibraryImporter.startupImportDone]）。
  /// 推到第一帧之后且不挡启动——它要打 20 次签名请求、跑几十秒；首页不依赖它，本地有
  /// 快照就直接画，没有就走网络。
  Future<void> _importLibraryOnce(LibraryImporter importer) async {
    await importer.markStartupImportDone();
    try {
      await importer.run();
    } catch (error) {
      // 失败不在用户面前冒任何东西：首页照常走网络，要更新去设置里点。
      debugPrint('[library] 首次导入失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'onedrama',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: switch (settings.theme) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      },
      routerConfig: appRouter,
      // 大字模式：只在开启时介入；关着就别动系统的字号设置。
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        if (!settings.largeText) return content;
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.3,
          maxScaleFactor: 1.3,
          child: content,
        );
      },
    );
  }
}
