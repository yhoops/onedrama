import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../theme.dart';
import 'pressable.dart';

/// 剧集海报卡。参考页里是「海报 + 左下角全集角标 + 标题 + 集数·分类」。
class DramaCard extends StatelessWidget {
  const DramaCard({super.key, required this.drama, this.heroTag, this.onTap});

  final Drama drama;

  /// Hero 标签。列表页与详情页传同一个，海报就能连成一口气飞过去。
  final String? heroTag;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final drama = this.drama;
    final palette = OneDramaColors.of(context);
    final episodes = drama.episodeCount.isNotEmpty
        ? drama.episodeCount
        : drama.totalEpisode;

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(OneDramaSizes.posterRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DramaCover(url: drama.cover),
          if (episodes.isNotEmpty)
            Positioned(
              left: 6,
              bottom: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.badge,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    '全 $episodes 集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Pressable(
      onTap: onTap,
      // 按下时轻微缩一下。比 splash 更贴手，也让密集的海报流有反馈。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: OneDramaSizes.posterAspect,
            child: heroTag == null
                ? poster
                : Hero(tag: heroTag!, child: poster),
          ),
          const SizedBox(height: 6),
          // 标题区固定两行高：有的剧名一行、有的两行，不固定的话副标题会参差，
          // 一行行的卡片看起来像没对齐。
          SizedBox(
            height: 36,
            child: Text(
              drama.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.28,
                fontWeight: FontWeight.w600,
                color: palette.primaryText,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _subtitle(drama),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.secondaryText),
          ),
        ],
      ),
    );
  }

  /// 「36集 · 真人剧」这一行。缺项就省掉，不留下孤零零的分隔点。
  static String _subtitle(Drama drama) {
    final episodes = drama.episodeCount.isNotEmpty
        ? drama.episodeCount
        : drama.totalEpisode;
    final parts = <String>[
      if (episodes.isNotEmpty) '$episodes集',
      if (drama.categoryName.isNotEmpty) drama.categoryName,
    ];
    if (parts.isEmpty) return drama.remark;
    return parts.join(' · ');
  }
}

/// 封面解码宽度。
///
/// 网格海报与详情页海报都用 [gridCoverWidth]：网格海报 161dp × 3（xxhdpi）= 483px，
/// 解 480 正好；详情页那张 104dp 用同一档，于是两处共用同一个缓存键——**Hero 飞行时
/// 不会掉成灰块**（Hero 默认外壳用的是目的地那一端的 widget，见 [coverFlightShuttle]）。
/// 详情页的模糊底图也是它，一张解码两处用。
const int gridCoverWidth = 480;

/// 列表行封面的解码宽度。
///
/// 榜单行 58dp、搜索行 68dp、我的行 62dp，×3 只有 174–204px，用 480 解是浪费：
/// 480 宽解出来约 1.32 MB/张，240 只有约 0.33 MB。按一遍正常使用算（首页四个标签
/// 72 张 + 榜单四个榜 80 行），解码内存从约 171 MB 降到约 92 MB——而 Flutter 的
/// `ImageCache` 默认上限是 100 MB。不降的话 LRU 一直在挤图，往回滑时上面那几张
/// 可能早被挤掉、得重新解码，**预加载的收益会被抵消一部分**。
const int rowCoverWidth = 240;

/// 封面。带磁盘缓存与淡入——列表滑动时不会闪白。
///
/// [memCacheWidth] 决定解码宽度，也就决定了 Flutter `ImageCache` 里的缓存键
/// （见 `CoverPrefetcher` 的说明）。要预热它就必须传同一个值。
class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.memCacheWidth = gridCoverWidth,
  });

  final String url;
  final BoxFit fit;

  /// 网格 / 详情海报那一档，或列表行的 [rowCoverWidth]。
  final int memCacheWidth;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _CoverFallback();
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      // 限一下解码宽度：海报在 2 列网格里用不到原始分辨率，省内存。
      memCacheWidth: memCacheWidth,
      fadeInDuration: const Duration(milliseconds: 220),
      placeholder: (context, url) => const _CoverFallback(),
      errorWidget: (context, url, error) => const _CoverFallback(),
    );
  }
}

/// 无图/加载中/失败都用它。刻意做成静态灰底——几十张卡各自跑 shimmer 会掉帧。
class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    final palette = OneDramaColors.of(context);
    return ColoredBox(
      color: palette.field,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: palette.secondaryText.withValues(alpha: 0.5),
          size: 28,
        ),
      ),
    );
  }
}

/// 打开详情。列表页统一走这里，省得每处都拼路由。
///
/// [heroTag] 是**这一处**封面的 Hero 标签（用 [coverHeroTag] 拼）。详情页拿它画自己的
/// Hero——两端一致才飞得起来；不给就整页淡入，没有共享元素。
void openDrama(BuildContext context, Drama drama, {String? heroTag}) {
  if (drama.sourceId.isEmpty) return;

  // 顺手把详情页要用的那一档也热上：列表行只解到 [rowCoverWidth]，而详情页的海报与
  // 模糊底图都是 [gridCoverWidth]。不热的话，飞行落地后海报会从灰块变成图（热一下
  // 只要一次磁盘读 + 解码，地址已经在磁盘缓存里了）。
  //
  // 缓存键与 context 无关——`CachedNetworkImageProvider.obtainKey` 直接返回自己
  // （`cached_network_image_provider.dart`），`ImageConfiguration` 不参与——所以在列表的
  // context 里热 480，一样能命中详情页那一次。从网格点进来时它本来就命中，等于空跑。
  if (drama.cover.isNotEmpty) {
    precacheImage(
      ResizeImage(
        CachedNetworkImageProvider(drama.cover),
        width: gridCoverWidth,
      ),
      context,
      // 封面会过期（签名地址带 x-expires）也会 404。热不上就算了，真打开详情页时
      // 组件自己会走 errorWidget。
      onError: (error, stackTrace) {},
    );
  }

  context.push(
    '/detail/${drama.sourceId}',
    extra: DramaPreview(drama: drama, heroTag: heroTag),
  );
}

/// 封面 Hero 的标签。**两端必须拼出同一个字符串**才会飞。
///
/// [scope] 是「页面 + 标签页」，例如 `t0`（首页·综合）/ `rank:hongguo-hot`。
/// 不能只用 `cover:{id}`：首页是 `PageView`、榜单是 `TabBarView`，**滑动时相邻两页同时
/// 在树里**（`PageView` 默认 `cacheExtent = 0`，但正在被拖进来的那一页当然要构建），
/// 而综合与真人剧、总热播与真人榜的内容高度重叠——同一个标签出现两个 Hero，
/// Flutter 会抛「multiple heroes that share the same tag within a subtree」
/// （`widgets/heroes.dart` 的 `_allHeroesFor`）。纯 debug 断言，release 下只会在
/// 二者之间随便挑一个，所以更容易被忽略。
String coverHeroTag(String scope, String dramaId) => 'cover:$scope:$dramaId';

/// 从列表点进详情时带过去的东西。
class DramaPreview {
  const DramaPreview({required this.drama, this.heroTag});

  /// 列表手里的快照。有它详情页就能立刻画出标题与封面，不必等详情请求。
  final Drama drama;

  /// 这一处封面的 Hero 标签。为空就没有共享元素。
  final String? heroTag;
}

/// 封面 Hero 的飞行外壳：用**来源**那一端的封面，而不是默认的目的地端。
///
/// 默认外壳取 `toHero.child`（`widgets/heroes.dart` 的 `_defaultHeroFlightShuttleBuilder`），
/// 也就是详情页那张 [gridCoverWidth]；而列表行只解到 [rowCoverWidth]——两端不是同一个
/// 缓存键，那张 480 的没被预热过，飞行一开始会先出灰块，等它解码完才显形。
/// 用来源端则是「你刚在屏幕上看到的那张图」，本来就在内存里。
///
/// 两个方向都成立：push 时来源是列表行，pop 时来源是详情页，都是「刚刚在看的那个」。
Widget coverFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) => (fromHeroContext.widget as Hero).child;
