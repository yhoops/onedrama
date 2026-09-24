import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

import '../data/database.dart';
import '../data/media_cache.dart';
import '../data/providers.dart';
import '../data/settings.dart';
import '../player/cenc_player.dart';
import '../player/decrypt_plan.dart';
import 'theme.dart';
import 'widgets/pressable.dart';

/// 打开播放页的参数。走 `extra` 传，不塞进路由参数。
class PlaybackRequest {
  const PlaybackRequest({
    required this.drama,
    required this.episodes,
    required this.index,
    this.startAtMs = 0,
  });

  final Drama drama;
  final List<Episode> episodes;
  final int index;
  final int startAtMs;
}

/// 打开播放页。详情页与选集都用它。
void openPlayer(
  BuildContext context, {
  required Drama drama,
  required List<Episode> episodes,
  required int index,
  int startAt = 0,
}) {
  if (episodes.isEmpty || index < 0) return;
  context.push(
    '/player',
    extra: PlaybackRequest(
      drama: drama,
      episodes: episodes,
      index: index.clamp(0, episodes.length - 1),
      startAtMs: startAt,
    ),
  );
}

/// 播放页。整页暗色，独立于全局主题。
///
/// 结构照参考页：顶部剧名 + 第几集/画质，右侧一条竖向控制栏，点屏出/隐，
/// 右上「…」拉起播放设置面板（选集 / 收藏 / 倍速 / 画质 + 亮度音量 + 简介）。
///
/// **加密流走「边下边解」**（`CencDecryptDataSource` + Dart 侧编的解密计划，见
/// ADR-0005）：先取到头部（`moov` 在那儿）就能开播，不用等整集下完；拖动进度条也
/// 正确，因为任意字节位置都能从对应的 counter 块起算。算不出计划时才退回
/// 「先下载整集再解」那条已离线验证过的路。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.request});

  final PlaybackRequest request;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  final CencPlayer _player = CencPlayer();

  late int _index = widget.request.index;
  Media? _media;
  String? _qualityLabel;

  bool _preparing = true;
  double _prepareProgress = 0;

  /// 准备阶段给用户的一句实话：现在是在取头部还是在等整集。
  String? _prepareNote;
  String? _error;

  CencPlayerState _state = const CencPlayerState();
  Timer? _poll;
  Timer? _hideControls;

  bool _controlsVisible = true;
  bool _locked = false;
  bool _favorite = false;
  double _speed = 1;
  double _brightness = 0.65;
  double _volume = 0.5;

  // 手势过程中的临时值。
  double? _seekPreviewMs;
  double _dragStartX = 0;
  Size? _surfaceSize;

  /// 提前抓下来的引用。
  ///
  /// `dispose()` 里**不能碰 `ref`**——riverpod 3 会直接抛「widget 即将/已经卸载时用
  /// ref 是不安全的」。而退出时正是最该落一次进度的时候，所以把要用的东西先存下来。
  /// 预取是异步的、退出时可能还在飞，它要用的东西同理。
  AppDatabase? _db;
  HongguoClient? _client;
  Dio? _dio;
  bool _rememberProgress = true;
  bool _autoPlayNext = true;
  bool _haptic = true;
  bool _prefetchEnabled = true;

  /// 预取在开播后**立刻**开始。
  ///
  /// 这里原本排的是「开播后等 10 秒」，初衷是别为「点进去看一眼就退」的人白下
  /// 14.6 MB。真机反馈否掉了它：实测一集 10.9–18.8 MB 只要 3–4 秒下完，而人往往看
  /// 十来秒就往下切——等 10 秒才开始，等于 13–14 秒才就绪，切集时照样要等加载。
  /// 所以改成开播即开始，代价（早早退出会白下十几 MB）按取舍接受。
  static const Duration _prefetchDelay = Duration.zero;

  Timer? _prefetchTimer;

  /// 在飞的那次预取。退出播放页要能把它掐掉。
  CancelToken? _prefetchCancel;

  /// 正在预取哪一集（避免重复起一次）。
  String? _prefetchingId;

  Episode get _episode => widget.request.episodes[_index];
  Drama get _drama => widget.request.drama;

  /// 把设置与数据库的引用同步到字段里。每次 build 调一次，开销可以忽略。
  void _syncRefs() {
    final settings = ref.read(settingsProvider);
    _rememberProgress = settings.rememberProgress;
    _autoPlayNext = settings.autoPlayNext;
    _prefetchEnabled = settings.prefetchNext;
    _haptic = settings.hapticFeedback;
    _db = ref.read(databaseProvider);
    _client = ref.read(hongguoClientProvider);
    _dio = ref.read(dioProvider);
  }

  @override
  void initState() {
    super.initState();
    _syncRefs();
    _speed = ref.read(settingsProvider).defaultSpeed;
    _favorite = ref.read(isFavoriteProvider(_drama.id)).value ?? false;
    _volume = 1;
    _prepare();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _hideControls?.cancel();
    _prefetchTimer?.cancel();
    // 退出就不下了：剩下的那几 MB 是纯浪费，下次进来会重新排。
    _prefetchCancel?.cancel();
    // 退出时把进度落一次——这是「记忆播放进度」最常见的兑现点。
    unawaited(_saveProgress());
    _player.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------- 取流、解密、播放 ----------

  /// 准备一集：能播本地文件就播本地，否则走流式，最后才退回「先下整集再解」。
  ///
  /// [override] 是用户在播放设置面板里**手动挑的画质**。它必须绕过本地缓存——磁盘上
  /// 那份是预取时挑的档，跟新挑的档不是同一路流。
  Future<void> _prepare({int? startAtMs, Media? override}) async {
    _prefetchTimer?.cancel();
    _prefetchCancel?.cancel();
    _prefetchCancel = null;
    _prefetchingId = null;

    setState(() {
      _preparing = true;
      _prepareProgress = 0;
      _prepareNote = null;
      _error = null;
    });

    try {
      final client = ref.read(hongguoClientProvider);
      final settings = ref.read(settingsProvider);

      // 预取过的：磁盘上就有明文，**一个网络请求都不用打**。宽高与档位列表在旁挂里
      // （见 `docs/adr/0009`）。旁挂丢了就退回取流——但文件照播，省下的仍是流式那段。
      File? local;
      Media? restored;
      if (override == null) {
        final cached = await episodeCacheFile(_episode.videoId);
        if (await cached.exists() && await cached.length() > 1024) {
          local = cached;
          restored = await readEpisodeSidecar(_episode.videoId);
        }
      }

      final Media media;
      if (override != null) {
        media = override;
      } else if (restored != null) {
        media = restored;
      } else {
        media = await client.resolveMedia(_drama.sourceId, _episode.videoId);
      }

      // 画质只在「刚从网络取回来」时才按设置挑：本地那份与旁挂里的都是**已经确定的
      // 那一档**，重挑一次只会让标签与画面对不上。
      final picked = override == null && restored == null
          ? _pickVariant(media, settings.preferredQuality)
          : media;
      // 定下真正要用哪个地址（主地址不通就换备选）。下游的头部取回、解密计划与
      // setMedia 全都读 picked.url，所以这一步必须在它们**之前**收敛掉。
      final settled = local == null ? await _settleAddress(picked) : picked;
      if (mounted) {
        setState(() {
          _media = settled;
          _qualityLabel = settled.quality > 0 ? '${settled.quality}P' : '自动';
          if (local != null) _prepareNote = '这一集已预取到本地，直接播';
        });
      }

      if (!mounted) return;
      if (!_player.isCreated) await _player.create();
      // 出画尺寸不在这里设：`_videoSurface` 会按片源比例（或整屏）调 setSurfaceSize，
      // 而且 `_prepare` 是从 initState 调的，那时 MediaQuery 还没就绪。

      // 能算出解密计划就走**流式**：只取头部（`moov` 在那里，约 1 MB）就够了，不用等
      // 整集下完。算不出计划（站点改了封装之类）再退回「先下载整集再解」那条已验证的路。
      Uint8List? plan;
      if (local == null && settled.isEncrypted) {
        try {
          plan = await _buildDecryptPlan(settled);
        } catch (_) {
          plan = null;
          if (mounted) {
            setState(() => _prepareNote = '流式解密不可用，改为先下载整集');
          }
        }
      }

      if (!mounted) return;
      if (local != null) {
        await _player.setMedia(url: local.uri.toString());
      } else if (plan != null) {
        await _player.setMedia(
          url: settled.url,
          referer: settled.referer,
          cencKey: settled.cencKey,
          decryptPlan: plan,
        );
      } else {
        final file = await prepareEpisode(
          dio: ref.read(dioProvider),
          media: settled,
          videoId: _episode.videoId,
          onProgress: (received, total) {
            if (!mounted || total <= 0) return;
            setState(() => _prepareProgress = received / total);
          },
        );
        if (!mounted) return;
        await _player.setMedia(url: file.uri.toString());
      }

      await _player.setSpeed(_speed);
      await _player.setVolume(_volume);

      final resumeMs =
          startAtMs ??
          (settings.rememberProgress
              ? (await ref.read(databaseProvider).resumePoint(_drama.id))
                        ?.positionMs ??
                    0
              : 0);
      // 上一集结尾的进度别把这一集拖到末尾——只在真的记过进度时跳。
      if (resumeMs > 3000) {
        await _player.seekTo(Duration(milliseconds: resumeMs));
      }

      await _player.play();
      if (mounted) setState(() => _preparing = false);
      _startPolling();
      _scheduleHideControls();
      _schedulePrefetch();
    } catch (failure) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = '$failure';
        });
      }
    }
  }

  /// 从同一次取流返回的画质里挑一路。
  ///
  /// `preferredQuality` 为 0 表示自动——此时用默认选中的那路（协议包已按分辨率与
  /// 编码挑过最优）。
  Media _pickVariant(Media media, int preferred) {
    if (preferred <= 0 || media.variants.isEmpty) return media;
    final variants = media.variants;
    Media best = media;
    var gap = 1 << 30;
    for (final variant in variants) {
      final current = (variant.quality - preferred).abs();
      if (current < gap) {
        best = variant;
        gap = current;
      }
    }
    return _attachVariants(best, variants);
  }

  /// 把档位列表挂回一个 [Media]。
  ///
  /// 档位列表挂在**外层**取流结果上，而 `media.variants` 里每一项自己是没有列表的
  /// （`selectAppMedia` 就是这么构造的）。「画质」面板的选项取自 `_media.variants`，
  /// 所以**任何一次「挑出一档当 `_media`」都必须把列表挂回去**——不挂的话，面板下一
  /// 秒就空了（`_showQualities` 见空即返回，按钮点了没反应）。
  Media _attachVariants(Media media, List<Media> variants) => Media(
    url: media.url,
    referer: media.referer,
    duration: media.duration,
    cencKey: media.cencKey,
    quality: media.quality,
    width: media.width,
    height: media.height,
    // 备选地址也要跟着走。漏了它，用户一切画质就落到一个没有备胎的档位上——
    // 主地址恰好被限时，一切画质就播不了，而换回去又好了，极难归因。
    backupUrls: media.backupUrls,
    variants: variants,
  );

  /// 只取流的头部（`moov` 就在开头），算出样本索引与等长替换补丁，编成解密计划。
  ///
  /// **这是流式解密的关键一步**：不用把 15 MB 下完才能开播。`moov` 实测约 210 KB，
  /// 取 1 MB 有足够余量（要给 `senc` 那种大盒子留空间）。
  Future<Uint8List> _buildDecryptPlan(Media media) async {
    final response = await ref
        .read(dioProvider)
        .get<List<int>>(
          media.url,
          options: Options(
            headers: <String, String>{
              'Referer': media.referer,
              'User-Agent': webUserAgent,
              'Range': 'bytes=0-1048575',
            },
            responseType: ResponseType.bytes,
            validateStatus: (_) => true,
          ),
        );
    final head = Uint8List.fromList(response.data ?? const <int>[]);
    if (head.length < 1024) {
      throw HongguoProtocolException('只取到 ${head.length} 字节头部，解析不了');
    }
    final index = CencIndex.parse(head);
    if (index == null) {
      throw HongguoProtocolException('头部里解不出 CENC 索引');
    }
    return encodeDecryptPlan(index, buildNeutralizingPatches(head));
  }

  /// 定地址：主地址不可达时依次试备选（`backup_url`），返回第一个能用的。
  ///
  /// **必须在建解密计划之前做**：头部和正片得来自同一个地址。先在备胎上取到头部、
  /// 正片却还打在主地址上，等于白试——主地址挂着的话正片照样播不出来。
  ///
  /// 判可达只取 1 字节（`Range: bytes=0-0`）：200 与 206 都算通。实测每档只多一个备选
  /// （落在另一个 CDN 主机上），所以这一步最多多打一个小请求；换来的是主地址被限时不用
  /// 用户手动重试。
  ///
  /// 全都不通时**把主地址原样交出去**，让播放器去报它自己的错——比在这里编一个
  /// 「都不可达」更有用，因为播放器的错误里带状态码。
  Future<Media> _settleAddress(Media media) async {
    if (media.backupUrls.isEmpty) return media;
    for (final address in media.allUrls) {
      try {
        final response = await ref.read(dioProvider).get<List<int>>(
          address,
          options: Options(
            headers: <String, String>{
              'Referer': media.referer,
              'User-Agent': webUserAgent,
              'Range': 'bytes=0-0',
            },
            responseType: ResponseType.bytes,
            validateStatus: (_) => true,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status != 200 && status != 206) continue;
        if (address == media.url) return media;
        // 取证痕迹：换了地址必须能从日志里看出来，否则「怎么这一集画质变了」只能靠猜。
        debugPrint('[media] 主地址不可达，改用备选：$address');
        return media.withUrl(address);
      } catch (_) {
        continue;
      }
    }
    return media;
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!_player.isCreated) return;
      final state = await _player.state();
      if (!mounted) return;

      final ended = state.playbackState == 4 || !state.isPlaying;
      setState(() => _state = state);

      if (state.error != null) {
        _poll?.cancel();
        setState(() => _error = state.error);
        return;
      }
      // 自动连播：演完了就切下一集。
      if (state.playbackState == 4) {
        _poll?.cancel();
        if (_autoPlayNext && _index + 1 < widget.request.episodes.length) {
          _switchTo(_index + 1);
        }
      } else if (ended) {
        // 暂停时顺手落一次进度。
        unawaited(_saveProgress());
      }
    });
  }

  Future<void> _saveProgress() async {
    final db = _db;
    final state = _state;
    if (!_rememberProgress || db == null || state.duration <= Duration.zero) {
      return;
    }
    try {
      await db.saveProgress(
        drama: _drama,
        videoId: _episode.videoId,
        episodeNumber: _episode.number,
        positionMs: state.position.inMilliseconds,
        durationMs: state.duration.inMilliseconds,
      );
      // 刷新只在页面还在时做——dispose 路径上碰 ref 会抛。
      if (mounted) {
        ref.invalidate(resumePointProvider(_drama.id));
        ref.invalidate(historyProvider);
      }
    } catch (_) {
      // 进度写不进去不该打断播放。
    }
  }

  void _switchTo(int index) {
    if (index < 0 || index >= widget.request.episodes.length) return;
    unawaited(_saveProgress());
    _poll?.cancel();
    setState(() {
      _index = index;
      _state = const CencPlayerState();
    });
    _prepare(startAtMs: 0);
  }

  // ---------- 预取下一集 ----------

  /// 排一次预取：当前集起播后再等 [_prefetchDelay]，然后去把下一集下下来。
  ///
  /// 延时是为了「点进去看一眼就退」的用法——那种情况下 14.6 MB 是白下的。退出播放页
  /// 会连同没到点的定时器一起取消。
  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    if (!_prefetchEnabled) return;
    if (_index + 1 >= widget.request.episodes.length) return;
    _prefetchTimer = Timer(_prefetchDelay, () => unawaited(_prefetchNext()));
  }

  /// 后台把下一集整集下完、解密、落盘，并把取流结果写成旁挂（`docs/adr/0009`）。
  ///
  /// **失败一律静默**：预取是「顺手多做的事」，它出问题不该在播放页上冒出任何东西——
  /// 切过去时照常走流式，用户至多觉得慢了一点。
  Future<void> _prefetchNext() async {
    final client = _client;
    final dio = _dio;
    if (client == null || dio == null || !_prefetchEnabled) return;

    final next = _index + 1;
    if (next >= widget.request.episodes.length) return;
    final episode = widget.request.episodes[next];
    if (_prefetchingId == episode.videoId) return;

    final target = await episodeCacheFile(episode.videoId);
    if (await target.exists() && await target.length() > 1024) return;

    final cancel = CancelToken();
    _prefetchCancel = cancel;
    _prefetchingId = episode.videoId;
    final startedAt = DateTime.now();
    try {
      final media = await client.resolveMedia(_drama.sourceId, episode.videoId);
      // 目标**与当前集同一档**：切过去不该跳画质。当前集若是预取来的，`_media` 就是
      // 磁盘上那一档，用它当目标；`_pickVariant` 会挑最接近的那一路。
      final picked = _pickVariant(media, _media?.quality ?? 0);
      // 预取也要定地址：整集下载打在主地址上，主地址挂了这一集就白预取（静默失败），
      // 切过去时又得现走流式。
      final settled = await _settleAddress(picked);
      final file = await prepareEpisode(
        dio: dio,
        media: settled,
        videoId: episode.videoId,
        cancelToken: cancel,
      );
      await writeEpisodeSidecar(
        episode.videoId,
        media: media,
        pickedQuality: picked.quality,
      );
      final pruned = await pruneEpisodeCache(protect: _protectedIds());
      // 刻意留的取证痕迹：切集前后的 `STATE_READY` 对比与「有没有真的预取到」都靠它
      // （`adb logcat -s flutter`）。同 `[spike]` 那套。
      debugPrint(
        '[prefetch] 第 ${episode.number} 集就绪 · ${picked.quality}P · '
        '${await file.length()} 字节 · '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms'
        '${pruned > 0 ? ' · 淘汰 $pruned 集' : ''}',
      );
    } catch (error) {
      debugPrint('[prefetch] 第 ${episode.number} 集放弃：$error');
    } finally {
      // 期间没被新的一次预取顶掉，才清标记。
      if (identical(_prefetchCancel, cancel)) {
        _prefetchCancel = null;
        _prefetchingId = null;
      }
    }
  }

  /// 正在播的这一集与下一集不能被淘汰。
  Set<String> _protectedIds() => <String>{
    _episode.videoId,
    if (_index + 1 < widget.request.episodes.length)
      widget.request.episodes[_index + 1].videoId,
  };

  // ---------- 手势 ----------

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleHideControls();
    } else {
      _hideControls?.cancel();
    }
  }

  /// 3 秒后自动隐藏控制栏。播放中才隐——暂停时留着，不然用户找不到播放键。
  void _scheduleHideControls() {
    _hideControls?.cancel();
    if (_locked || !_state.isPlaying) return;
    _hideControls = Timer(const Duration(seconds: 3), () {
      if (mounted && _state.isPlaying) setState(() => _controlsVisible = false);
    });
  }

  void _bump() {
    if (_haptic) HapticFeedback.selectionClick();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_locked) return;
    final width = MediaQuery.sizeOf(context).width;
    final delta = -details.delta.dy / 260;
    setState(() {
      if (_dragStartX < width / 2) {
        _brightness = (_brightness + delta).clamp(0.05, 1);
      } else {
        _volume = (_volume + delta).clamp(0, 1);
      }
    });
    _player.setVolume(_volume);
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_locked || _state.duration <= Duration.zero) return;
    final width = MediaQuery.sizeOf(context).width;
    final current = _seekPreviewMs ?? _state.position.inMilliseconds.toDouble();
    final delta = details.delta.dx / width * _state.duration.inMilliseconds;
    setState(() {
      _seekPreviewMs = (current + delta).clamp(
        0,
        _state.duration.inMilliseconds.toDouble(),
      );
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final target = _seekPreviewMs;
    _seekPreviewMs = null;
    if (target == null) return;
    _bump();
    unawaited(_player.seekTo(Duration(milliseconds: target.round())));
  }

  // ---------- 控制动作 ----------

  Future<void> _togglePlay() async {
    _bump();
    if (_state.isPlaying) {
      await _player.pause();
      unawaited(_saveProgress());
    } else {
      await _player.play();
    }
    _scheduleHideControls();
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _player.setSpeed(speed);
  }

  Future<void> _setQuality(Media media) async {
    // 面板递过来的那一档来自 `_media.variants`，自己的列表是空的——挂回去，否则挑了
    // 一次画质之后「画质」面板就打不开了。
    final picked = _attachVariants(media, _media?.variants ?? media.variants);
    setState(() {
      _media = picked;
      _qualityLabel = picked.quality > 0 ? '${picked.quality}P' : '自动';
    });
    // 磁盘上那份是**预取时挑的那一档**，跟刚挑的这档不是同一路流。留着它，下次再看
    // 这一集会莫名其妙地退回旧画质（画面一个新档、标签一个旧档也说不通），所以丢掉。
    // 换画质仍要重新取一次流——流式数据源做完就不用了，见 `docs/plan.md` 阶段 1 的 4b 收尾。
    await dropEpisodeCache(_episode.videoId);
    await _prepare(startAtMs: _state.position.inMilliseconds, override: picked);
  }

  Future<void> _toggleFullscreen() async {
    _bump();
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (landscape) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  // ---------- 界面 ----------

  /// 视频画面：按**源片比例**显示（contain，比例不符处留黑边）。
  ///
  /// 要点是**出画缓冲与布局盒同一个比例**——比例一致时不会有任何缩放，画幅就是原样。
  ///
  /// 这里曾经靠「ExoPlayer 自己会 letterbox」把**整屏**尺寸喂给它，但本插件是零 UI 的
  /// （没有 `PlayerView` / `AspectRatioFrameLayout`，见 [ADR-0002]），没有任何东西做比例
  /// 校正，于是解码帧被硬拉进整屏缓冲 → 竖屏剧被纵向拉长、横屏剧更夸张。真机截图里
  /// 上下左右都没有黑边，就是这条路径的表现。
  ///
  /// 上游没给尺寸时（网页 / 备用源只有 URL）退回铺满：宁可铺满，也不要猜一个比例。
  ///
  /// [ADR-0002]: ../../docs/adr/0002-thin-exoplayer-plugin-owns-cenc.md
  Widget _videoSurface() {
    final media = _media;
    final ratio = media?.aspectRatio;

    if (media == null || ratio == null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          _scheduleSurfaceSize(constraints.biggest);
          return _textureOrBlank();
        },
      );
    }

    // 缓冲设成原生像素尺寸：帧到缓冲是 1:1，连重采样都省了；Flutter 再把整张纹理等比
    // 缩到布局盒。真正的画幅由 AspectRatio 决定。
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: Builder(
          builder: (context) {
            _scheduleSurfaceSize(
              Size(media.width.toDouble(), media.height.toDouble()),
            );
            return _textureOrBlank();
          },
        ),
      ),
    );
  }

  Widget _textureOrBlank() => _player.isCreated
      ? Texture(textureId: _player.textureId)
      : const ColoredBox(color: Colors.black);

  /// 把出画缓冲改成 [size]。同一尺寸只设一次；在 build 里调，实际设置推到帧后。
  void _scheduleSurfaceSize(Size size) {
    if (size.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_player.isCreated) return;
      if (_surfaceSize == size) return;
      _surfaceSize = size;
      _player.setSurfaceSize(size.width.round(), size.height.round());
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncRefs();
    final requestedSide = ref.watch(settingsProvider).controlSide;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _videoSurface(),
          // 亮度手势的遮罩：不改系统亮度，只压一层黑——不用平台通道，也没有权限问题。
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 1 - _brightness),
            ),
          ),
          _GestureLayer(
            onTap: _locked ? () {} : _toggleControls,
            onDoubleTap: _locked ? null : () => unawaited(_togglePlay()),
            onVerticalDragStart: (details) =>
                _dragStartX = details.localPosition.dx,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
          ),
          if (_preparing)
            _PreparingOverlay(progress: _prepareProgress, note: _prepareNote),
          if (_error != null)
            _ErrorOverlay(
              message: _error!,
              onRetry: () => _prepare(),
              onExit: () => context.pop(),
            ),
          if (_locked) _LockBadge(onTap: () => setState(() => _locked = false)),
          if (!_preparing && _error == null)
            _Controls(
              visible: _controlsVisible || !_state.isPlaying,
              side: requestedSide,
              drama: _drama,
              episode: _episode,
              episodeCount: widget.request.episodes.length,
              qualityLabel: _qualityLabel,
              state: _state,
              seekPreviewMs: _seekPreviewMs,
              locked: _locked,
              onBack: () => context.pop(),
              onToggle: () => unawaited(_togglePlay()),
              onPrev: _index > 0 ? () => _switchTo(_index - 1) : null,
              onNext: _index + 1 < widget.request.episodes.length
                  ? () => _switchTo(_index + 1)
                  : null,
              onSeek: (minutes) => unawaited(_player.seekTo(minutes)),
              onToggleFullscreen: () => unawaited(_toggleFullscreen()),
              onLock: () => setState(() {
                _locked = true;
                _controlsVisible = false;
              }),
              onCollapse: () => setState(() => _controlsVisible = false),
              onOpenSheet: _openSheet,
            ),
        ],
      ),
    );
  }

  Future<void> _openSheet() async {
    _hideControls?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SettingsSheet(
        drama: _drama,
        episodes: widget.request.episodes,
        currentIndex: _index,
        media: _media,
        speed: _speed,
        brightness: _brightness,
        volume: _volume,
        favorite: _favorite,
        onPickEpisode: (index) {
          Navigator.of(sheetContext).pop();
          _switchTo(index);
        },
        onPickSpeed: (speed) => unawaited(_setSpeed(speed)),
        onPickQuality: (media) {
          Navigator.of(sheetContext).pop();
          unawaited(_setQuality(media));
        },
        onBrightness: (value) {
          setState(() => _brightness = value);
        },
        onVolume: (value) {
          setState(() => _volume = value);
          unawaited(_player.setVolume(value));
        },
        onToggleFavorite: () async {
          final next = !_favorite;
          await ref.read(databaseProvider).setFavorite(_drama, next);
          ref.invalidate(isFavoriteProvider(_drama.id));
          ref.invalidate(favoritesProvider);
          if (mounted) setState(() => _favorite = next);
        },
        onExit: () {
          Navigator.of(sheetContext).pop();
          context.pop();
        },
      ),
    );
    if (mounted) _scheduleHideControls();
  }
}

/// 手势层。只接管手势，不画东西。
class _GestureLayer extends StatelessWidget {
  const _GestureLayer({
    required this.onTap,
    required this.onDoubleTap,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
  });

  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<DragStartDetails> onVerticalDragStart;
  final ValueChanged<DragUpdateDetails> onVerticalDragUpdate;
  final ValueChanged<DragUpdateDetails> onHorizontalDragUpdate;
  final ValueChanged<DragEndDetails> onHorizontalDragEnd;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    onDoubleTap: onDoubleTap,
    onVerticalDragStart: onVerticalDragStart,
    onVerticalDragUpdate: onVerticalDragUpdate,
    onHorizontalDragUpdate: onHorizontalDragUpdate,
    onHorizontalDragEnd: onHorizontalDragEnd,
  );
}

class _PreparingOverlay extends StatelessWidget {
  const _PreparingOverlay({required this.progress, this.note});

  final double progress;

  /// 一句实话：现在是在取头部，还是在等整集下完。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final downloading = progress > 0 && progress < 1;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                value: downloading ? progress : null,
                strokeWidth: 2.6,
                color: playerAccent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              downloading
                  ? '下载并解密 ${(progress * 100).toStringAsFixed(0)}%'
                  : '准备中…',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            Text(
              note ?? '流式解密：取到头部就能开播',
              style: const TextStyle(fontSize: 11.5, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onExit,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black87,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 40),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: onExit,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                  ),
                  child: const Text('返回'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(backgroundColor: playerAccent),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 锁屏后留在屏上的那把锁。点一下解锁。
class _LockBadge extends StatelessWidget {
  const _LockBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    top: MediaQuery.paddingOf(context).top + 12,
    child: Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: Color(0x66000000),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.lock_outline, size: 19, color: Colors.white),
      ),
    ),
  );
}

/// 控制层：顶栏 + 中央播放键 + 右侧竖栏。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.visible,
    required this.side,
    required this.drama,
    required this.episode,
    required this.episodeCount,
    required this.qualityLabel,
    required this.state,
    required this.seekPreviewMs,
    required this.locked,
    required this.onBack,
    required this.onToggle,
    required this.onPrev,
    required this.onNext,
    required this.onSeek,
    required this.onToggleFullscreen,
    required this.onLock,
    required this.onCollapse,
    required this.onOpenSheet,
  });

  final bool visible;
  final ControlSide side;
  final Drama drama;
  final Episode episode;
  final int episodeCount;
  final String? qualityLabel;
  final CencPlayerState state;
  final double? seekPreviewMs;
  final bool locked;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onLock;
  final VoidCallback onCollapse;
  final VoidCallback onOpenSheet;

  Duration get _shown => seekPreviewMs == null
      ? state.position
      : Duration(milliseconds: seekPreviewMs!.round());

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Stack(
        children: [
          _TopBar(
            drama: drama,
            episode: episode,
            episodeCount: episodeCount,
            qualityLabel: qualityLabel,
            onBack: onBack,
            onOpenSheet: onOpenSheet,
          ),
          Align(
            alignment: Alignment.center,
            child: _CenterPlayButton(playing: state.isPlaying, onTap: onToggle),
          ),
          Align(
            alignment: side == ControlSide.left
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: _RightRail(
              playing: state.isPlaying,
              position: _shown,
              duration: state.duration,
              episodeNumber: episode.number,
              episodeCount: episodeCount,
              seeking: seekPreviewMs != null,
              onToggle: onToggle,
              onPrev: onPrev,
              onNext: onNext,
              onSeek: onSeek,
              onToggleFullscreen: onToggleFullscreen,
              onLock: onLock,
              onCollapse: onCollapse,
            ),
          ),
        ],
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.drama,
    required this.episode,
    required this.episodeCount,
    required this.qualityLabel,
    required this.onBack,
    required this.onOpenSheet,
  });

  final Drama drama;
  final Episode episode;
  final int episodeCount;
  final String? qualityLabel;
  final VoidCallback onBack;
  final VoidCallback onOpenSheet;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 0,
    child: Container(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 8,
        left: 8,
        right: 8,
        bottom: 12,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  drama.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '第 ${episode.number} / $episodeCount 集'
                  '${qualityLabel == null ? '' : ' · $qualityLabel'}',
                  style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onOpenSheet,
            icon: const Icon(Icons.more_horiz, color: Colors.white),
          ),
        ],
      ),
    ),
  );
}

class _CenterPlayButton extends StatelessWidget {
  const _CenterPlayButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: playing ? 0 : 1,
    duration: const Duration(milliseconds: 160),
    child: IgnorePointer(
      ignoring: playing,
      child: Pressable(
        onTap: onTap,
        scale: 0.9,
        child: Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.22),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 42,
            color: Colors.white,
          ),
        ),
      ),
    ),
  );
}

/// 右侧（或左侧）那条竖向控制栏。参考页的播放页就是它。
class _RightRail extends StatelessWidget {
  const _RightRail({
    required this.playing,
    required this.position,
    required this.duration,
    required this.episodeNumber,
    required this.episodeCount,
    required this.seeking,
    required this.onToggle,
    required this.onPrev,
    required this.onNext,
    required this.onSeek,
    required this.onToggleFullscreen,
    required this.onLock,
    required this.onCollapse,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final int episodeNumber;
  final int episodeCount;
  final bool seeking;
  final VoidCallback onToggle;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onLock;
  final VoidCallback onCollapse;

  static String _clock(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final value = total <= 0
        ? 0.0
        : (position.inMilliseconds / total).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x59000000),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RailButton(
              icon: Icons.keyboard_arrow_up_rounded,
              label: '收起',
              // 参考页顶上那个 chevron 是收起控制栏，不是锁屏。
              onTap: onCollapse,
            ),
            _RailButton(icon: Icons.skip_previous_rounded, onTap: onPrev),
            // 播放键在这条栏里是最大的一颗，参考页也是。
            Pressable(
              onTap: onToggle,
              scale: 0.92,
              child: Container(
                width: 46,
                height: 46,
                margin: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 26,
                  color: Colors.black,
                ),
              ),
            ),
            Text(
              '$episodeNumber / $episodeCount',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            // 参考页：进度条上方是当前时间，下方是总时长。
            Text(
              seeking ? '跳到 ${_clock(position)}' : '进度',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
            const SizedBox(height: 2),
            Text(
              _clock(position),
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            _SeekSlider(
              value: value,
              total: total,
              seeking: seeking,
              onSeek: onSeek,
            ),
            const SizedBox(height: 4),
            Text(
              _clock(duration),
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 6),
            _RailButton(icon: Icons.skip_next_rounded, onTap: onNext),
            _RailButton(
              icon: Icons.fullscreen_rounded,
              onTap: onToggleFullscreen,
            ),
            _RailButton(icon: Icons.lock_outline, onTap: onLock),
          ],
        ),
      ),
    );
  }
}

/// 竖向进度条。`RotatedBox` 把横向 Slider 转过来，省得自己写手势。
class _SeekSlider extends StatelessWidget {
  const _SeekSlider({
    required this.value,
    required this.total,
    required this.seeking,
    required this.onSeek,
  });

  final double value;
  final int total;
  final bool seeking;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) => SizedBox(
    // 宽和**高**都必须给死：RotatedBox 会把子节点的约束对调，只给高度的话滑块
    // 在横向拿到无界宽度、撑满屏幕，转过来就是一条横贯全屏的暗色面板。
    width: 40,
    height: 110,
    child: RotatedBox(
      quarterTurns: 3,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2.5,
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: SliderComponentShape.noOverlay,
        ),
        child: Slider(
          value: value,
          onChanged: total <= 0
              ? null
              : (next) =>
                    onSeek(Duration(milliseconds: (next * total).round())),
        ),
      ),
    ),
  );
}

class _RailButton extends StatelessWidget {
  const _RailButton({required this.icon, this.label, this.onTap});

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: IconButton(
      onPressed: onTap,
      iconSize: label == null ? 21 : 17,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      icon: Icon(
        icon,
        color: onTap == null ? Colors.white24 : Colors.white,
        size: label == null ? 21 : 17,
      ),
    ),
  );
}

/// 播放设置面板。参考页的那块：选集 / 收藏 / 倍速 / 画质 + 亮度音量 + 简介 + 退出播放。
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.drama,
    required this.episodes,
    required this.currentIndex,
    required this.media,
    required this.speed,
    required this.brightness,
    required this.volume,
    required this.favorite,
    required this.onPickEpisode,
    required this.onPickSpeed,
    required this.onPickQuality,
    required this.onBrightness,
    required this.onVolume,
    required this.onToggleFavorite,
    required this.onExit,
  });

  final Drama drama;
  final List<Episode> episodes;
  final int currentIndex;
  final Media? media;
  final double speed;
  final double brightness;
  final double volume;
  final bool favorite;
  final ValueChanged<int> onPickEpisode;
  final ValueChanged<double> onPickSpeed;
  final ValueChanged<Media> onPickQuality;
  final ValueChanged<double> onBrightness;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleFavorite;
  final VoidCallback onExit;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late double _speed = widget.speed;
  late double _brightness = widget.brightness;
  late double _volume = widget.volume;

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final quality = widget.media?.quality ?? 0;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 剧名与右上角的关闭键同一行——参考页的样式。
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.drama.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Pressable(
                  onTap: () => Navigator.of(context).pop(),
                  scale: 0.88,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 22, color: Colors.white70),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '第 ${widget.episodes[widget.currentIndex].number} 集 · '
              '共 ${widget.episodes.length} 集',
              style: const TextStyle(fontSize: 12.5, color: Colors.white54),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _SheetAction(
                  icon: Icons.grid_view_rounded,
                  label: '选集',
                  onTap: _showEpisodes,
                ),
                const SizedBox(width: 10),
                _SheetAction(
                  icon: widget.favorite
                      ? Icons.favorite
                      : Icons.favorite_border,
                  label: '收藏',
                  highlighted: widget.favorite,
                  onTap: widget.onToggleFavorite,
                ),
                const SizedBox(width: 10),
                _SheetAction(
                  icon: Icons.speed_rounded,
                  label: '${_speed}x',
                  onTap: _showSpeeds,
                ),
                const SizedBox(width: 10),
                _SheetAction(
                  icon: Icons.high_quality_rounded,
                  label: quality > 0 ? '${quality}P' : '自动',
                  onTap: _showQualities,
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SliderRow(
              icon: Icons.brightness_6,
              label: '亮度',
              value: _brightness,
              display: '${(_brightness * 100).round()}%',
              onChanged: (value) {
                setState(() => _brightness = value);
                widget.onBrightness(value);
              },
            ),
            _SliderRow(
              icon: Icons.volume_up,
              label: '音量',
              value: _volume,
              display: '${(_volume * 100).round()}%',
              onChanged: (value) {
                setState(() => _volume = value);
                widget.onVolume(value);
              },
            ),
            if (widget.drama.intro.isNotEmpty ||
                widget.drama.desc.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                widget.drama.intro.isNotEmpty
                    ? widget.drama.intro
                    : widget.drama.desc,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: Colors.white54,
                ),
              ),
            ],
            const SizedBox(height: 18),
            _SheetRow(
              icon: Icons.gesture,
              label: '手势操作说明',
              onTap: _showGestureHelp,
            ),
            const SizedBox(height: 10),
            _SheetRow(icon: Icons.logout, label: '退出播放', onTap: widget.onExit),
          ],
        ),
      ),
    );
  }

  Future<void> _showEpisodes() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.5,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选集',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.5,
                  ),
                  itemCount: widget.episodes.length,
                  itemBuilder: (context, index) {
                    final watching = index == widget.currentIndex;
                    return Pressable(
                      onTap: () => Navigator.of(sheetContext).pop(index),
                      scale: 0.92,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: watching ? playerAccent : Colors.white12,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${widget.episodes[index].number}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: watching
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) widget.onPickEpisode(picked);
  }

  Future<void> _showSpeeds() async {
    final picked = await _pick<double>(
      title: '倍速',
      options: [for (final speed in _speeds) (speed, '${speed}x')],
      current: _speed,
    );
    if (picked == null) return;
    setState(() => _speed = picked);
    widget.onPickSpeed(picked);
  }

  Future<void> _showQualities() async {
    final variants = widget.media?.variants ?? const <Media>[];
    final current = widget.media;
    if (variants.isEmpty || current == null) return;
    final picked = await _pick<Media>(
      title: '画质',
      options: [
        for (final variant in variants)
          (variant, variant.quality > 0 ? '${variant.quality}P' : '自动'),
      ],
      // 按**档位**认当前项，不按对象身份：`Media` 没有值相等语义，而当前项与列表项
      // 是两次构造出来的，身份比对永远为 false——勾会一直不出现。
      current: variants.firstWhere(
        (variant) => variant.quality == current.quality,
        orElse: () => current,
      ),
    );
    if (picked != null) widget.onPickQuality(picked);
  }

  Future<T?> _pick<T>({
    required String title,
    required List<(T, String)> options,
    required T? current,
  }) => showModalBottomSheet<T>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1D),
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
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          for (final option in options)
            ListTile(
              title: Text(
                option.$2,
                style: const TextStyle(color: Colors.white),
              ),
              trailing: option.$1 == current
                  ? const Icon(Icons.check, size: 20, color: playerAccent)
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(option.$1),
            ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );

  Future<void> _showGestureHelp() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1D),
      title: const Text(
        '手势操作说明',
        style: TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: const Text(
        '· 单击屏幕：显示 / 隐藏控制栏\n'
        '· 双击屏幕：播放 / 暂停\n'
        '· 左半屏上下滑：调亮度\n'
        '· 右半屏上下滑：调音量\n'
        '· 左右滑：拖进度\n'
        '· 点锁图标：锁定控制栏',
        style: TextStyle(color: Colors.white70, height: 1.8, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Pressable(
      onTap: onTap,
      scale: 0.95,
      // 参考页里这是个近方形的块，图标与文案**都在块内**。
      child: Container(
        // 宽度得自己撑满：只给高度约束时，Container 在没约束的那一轴上会缩到跟
        // child 一样宽——child 是图标/一行小字，于是按钮变成一根竖条。
        // Expanded 撑开的是外框，装饰盒不跟着走。
        width: double.infinity,
        height: 64,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: highlighted ? playerAccent : Colors.white,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: highlighted ? playerAccent : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.display,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final double value;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: Colors.white54),
      const SizedBox(width: 10),
      SizedBox(
        width: 34,
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.5,
            activeTrackColor: playerAccent,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(value: value, onChanged: onChanged),
        ),
      ),
      SizedBox(
        width: 40,
        child: Text(
          display,
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 11.5, color: Colors.white54),
        ),
      ),
    ],
  );
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white10,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Colors.white54),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
          ],
        ),
      ),
    ),
  );
}
