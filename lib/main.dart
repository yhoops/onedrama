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

class OneDramaApp extends ConsumerWidget {
  const OneDramaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
