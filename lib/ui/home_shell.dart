import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme.dart';

/// 底栏外壳：短剧库 / 我的 / 设置。
///
/// 用 `StatefulShellRoute` 而不是自己管 IndexedStack——三个分支各自保留滚动位置与
/// 状态，来回切页不重建。
///
/// 代价是 `IndexedStack` **瞬切、没有过渡**，切页会显得硬。这里在 body 外面补一层
/// 「淡入 + 轻微上移」：切换瞬间整块重放一次，新页淡入，旧页不参与（它已经被换掉了）。
/// 只动 opacity 与 translate，压在 130ms 内。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: OneDramaSizes.branchFadeDuration,
    value: 1,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.navigationShell.currentIndex;
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 分支切换只从这里认：点底栏、以及别的入口（深链）都收敛到这一处。
    final current = widget.navigationShell.currentIndex;
    if (current == _index) return;
    _index = current;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return Scaffold(
      body: AnimatedBuilder(
        animation: _fade,
        builder: (context, child) {
          final progress = _fade.value;
          return Opacity(
            opacity: progress,
            child: Transform.translate(
              offset: Offset(
                0,
                (1 - progress) * OneDramaSizes.branchFadeOffset,
              ),
              child: child,
            ),
          );
        },
        child: widget.navigationShell,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: widget.navigationShell.currentIndex,
        // 再点当前页就回到该分支的根——这是移动端的通用预期。
        onTap: (index) => widget.navigationShell.goBranch(
          index,
          initialLocation: index == widget.navigationShell.currentIndex,
        ),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        backgroundColor: palette.surface,
        selectedItemColor: palette.accent,
        unselectedItemColor: palette.secondaryText,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.movie_filter_outlined),
            activeIcon: Icon(Icons.movie_filter),
            label: '短剧库',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: '我的',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.tune_outlined),
            activeIcon: Icon(Icons.tune),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
