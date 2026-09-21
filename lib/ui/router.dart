import 'package:go_router/go_router.dart';

import 'detail_page.dart';
import 'home_shell.dart';
import 'library_page.dart';
import 'mine_page.dart';
import 'player_page.dart';
import 'ranking_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'widgets/drama_card.dart';

/// 全局路由。
///
/// 底栏三页走 `StatefulShellRoute`（各自保留状态）；搜索 / 详情 / 播放 / 榜单是压在上面
/// 的整页，返回即回原处。
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (context, state) => const LibraryPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/mine',
              builder: (context, state) => const MinePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(path: '/rank', builder: (context, state) => const RankingsPage()),
    GoRoute(
      path: '/search',
      builder: (context, state) =>
          SearchPage(initialKeyword: state.uri.queryParameters['q'] ?? ''),
    ),
    GoRoute(
      path: '/detail/:seriesId',
      builder: (context, state) {
        // 列表页会顺手把快照与**那一处**封面的 hero 标签带过来（见 DramaPreview）：
        // 有快照就能立刻画出标题与封面；有标签才能让封面从被点的那张卡上飞过来。
        // 深链直接进详情时没有 extra，两个都是空的。
        final extra = state.extra;
        final preview = extra is DramaPreview ? extra : null;
        return DetailPage(
          seriesId: state.pathParameters['seriesId'] ?? '',
          preview: preview?.drama,
          heroTag: preview?.heroTag,
        );
      },
    ),
    GoRoute(
      path: '/player',
      builder: (context, state) =>
          PlayerPage(request: state.extra! as PlaybackRequest),
    ),
  ],
);
