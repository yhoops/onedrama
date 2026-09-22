import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database.dart';
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
    // 每次启动自动更新一遍剧库（`docs/adr/0008`）。
    //
    // **推到第一帧之后**，而且不 await：它要打 20 次签名请求、跑几十秒，绝不能挡启动。
    // 首页不依赖它——本地有快照就直接画，没有就走网络。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 启动这一轮失败不在用户面前冒任何东西：首页照常走网络，下次启动再试。
      unawaited(ref.read(libraryImporterProvider).run());
      // 榜单预热。走 web 主机（免签名），与上面那轮导入走的 app 主机不是同一路，
      // 所以并发跑不抢接口——它让「第一次进榜单」不用等网络。见 `data/ranking_warmer.dart`。
      unawaited(ref.read(rankingWarmerProvider).run());
    });
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
