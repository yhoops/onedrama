import 'package:flutter/material.dart';

import 'widgets/page_transition.dart';

/// 播放页专用的强调色。
///
/// 播放页整页暗色、**独立于全局主题**（见 `player_page.dart` 的说明），所以它不跟
/// 亮度走：固定用深色那一档的亮粉红，压在黑底上才够劲。这里放一份是为了让
/// [OneDramaColors.dark] 与它同源，不出现两个字面量。
const Color playerAccent = Color(0xFFFF4C75);

/// 参考页的配色与尺寸。集中放这里，页面里不写死颜色。
///
/// **两套值，按亮度取**：浅色照参考页取；深色是从
/// `参考的前端页面/深色1.jpg`、`深色2.jpg` 上直接取样的（页面底 `#0C0D12`、
/// 卡片面 `#12151C`、输入框 `#17181D`、分隔线 `#20242D`、强调色 `#FF4C75`）。
///
/// 页面里一律用 `OneDramaColors.of(context)` 取**当前亮度那一套**。直接写死
/// [light] 或 [dark] 的字段会让深色模式失效——那正是这一版之前的状态。
class OneDramaColors {
  const OneDramaColors._({
    required this.accent,
    required this.accentSoft,
    required this.pageBackground,
    required this.surface,
    required this.field,
    required this.primaryText,
    required this.secondaryText,
    required this.badge,
    required this.divider,
  });

  static const OneDramaColors light = OneDramaColors._(
    accent: Color(0xFFF0416C),
    accentSoft: Color(0xFFFFE9EF),
    pageBackground: Color(0xFFF6F6F8),
    surface: Colors.white,
    field: Color(0xFFF1F1F4),
    primaryText: Color(0xFF1A1A1A),
    secondaryText: Color(0xFF9A9AA0),
    badge: Color(0xCC1A1A1A),
    divider: Color(0xFFEFEFF2),
  );

  static const OneDramaColors dark = OneDramaColors._(
    // 深色下强调色比浅色亮一档，参考图的播放键与选中下划线都是这个值。
    accent: playerAccent,
    // 强调色的深底（选集选中格、标签底），用强调色压暗到卡片面上。
    accentSoft: Color(0xFF3D1F2C),
    pageBackground: Color(0xFF0C0D12),
    surface: Color(0xFF12151C),
    field: Color(0xFF17181D),
    primaryText: Color(0xFFF4F5FA),
    secondaryText: Color(0xFF8790A1),
    // 角标压在封面上，两种亮度下都该是半透明黑。
    badge: Color(0xCC1A1A1A),
    divider: Color(0xFF20242D),
  );

  /// 当前亮度那一套。页面 build 里第一行取它，之后只用它的字段。
  static OneDramaColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// 强调色：底栏选中、按钮、开关、进度条。
  final Color accent;

  /// 强调色的浅/深底，用于标签、选中态背景。
  final Color accentSoft;

  final Color pageBackground;
  final Color surface;

  /// 搜索框、题材 chip 的浅底。
  final Color field;

  final Color primaryText;
  final Color secondaryText;

  /// 卡面「全 N 集」角标的半透明黑。
  final Color badge;

  final Color divider;
}

/// 常用圆角与间距。参考页的卡片圆角约 12，搜索框是全圆角。
class OneDramaSizes {
  const OneDramaSizes._();

  static const double cardRadius = 12;
  static const double posterRadius = 12;
  static const double pagePadding = 14;
  static const double gridGap = 10;

  /// 海报统一用 3:4。参考页是参差瀑布流，但封面尺寸未知，
  /// 瀑布流会在图片加载完时跳版；固定比例没有跳动。
  static const double posterAspect = 3 / 4;

  /// 按压反馈：缩到多少、用多久。
  ///
  /// 海报卡原本就是 0.96 / 110ms（见 `drama_card.dart`），这里把它提成唯一来源，
  /// 其余可点面统一跟上——一套手感比每处各调一个数重要。
  static const double pressScale = 0.96;
  static const Duration pressDuration = Duration(milliseconds: 110);

  /// 底栏切页与路由转场。**两个数字刻意不同**，别再合并：
  ///
  /// - **路由**（`routeFade*`）进出的是层级，180ms + 上移 12px：慢一点才读得出方向感。
  /// - **底栏**（`branchFade*`）是平级切换，130ms + 上移 10px：它是最常被点的操作
  ///   （来回切三个页），快一点更利落，而平级切换本来就没有方向可言。
  ///
  /// 两者都收在这里。之前底栏那套在 `home_shell.dart`、路由那套在 `pageTransitionsTheme`，
  /// 改一次手感要翻两个文件、还容易只改一处。
  static const Duration routeFadeDuration = Duration(milliseconds: 180);
  static const double routeFadeOffset = 12;

  static const Duration branchFadeDuration = Duration(milliseconds: 130);
  static const double branchFadeOffset = 10;
}

/// 全局主题。
///
/// 除了给 Material 组件（开关、弹窗、底部面板…）一套对得上的 ColorScheme，
/// 也要让 [OneDramaColors.of] 能按 brightness 取到正确的色板——两边用的是同一份值。
ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;
  final palette = isDark ? OneDramaColors.dark : OneDramaColors.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: brightness,
      ).copyWith(
        primary: palette.accent,
        onPrimary: Colors.white,
        surface: palette.surface,
        onSurface: palette.primaryText,
        onSurfaceVariant: palette.secondaryText,
        primaryContainer: palette.accentSoft,
        onPrimaryContainer: palette.accent,
        // 输入框、chip 这类「比页面底亮一档」的填充色。
        surfaceContainerHighest: palette.field,
        outlineVariant: palette.divider,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.pageBackground,
    dividerColor: palette.divider,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.pageBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: palette.primaryText),
      titleTextStyle: TextStyle(
        color: palette.primaryText,
        fontSize: 24,
        fontWeight: FontWeight.w800,
      ),
    ),
    // 页面切换：新页淡入 + 上移，旧页静止。**不是**系统的
    // `FadeForwardsPageTransitionsBuilder`——那套 450ms、两页各横滑 25%，是 M3 里最重的
    // 一档，和底栏那套语汇对不上。理由与实现见 `widgets/page_transition.dart`。
    // 只配 Android：这个 App 就只发 Android，不引入 cupertino 那一套。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeUpPageTransitionsBuilder(),
      },
    ),
    splashFactory: InkSparkle.splashFactory,
  );
}
