import 'package:flutter/services.dart';

/// 播放器状态快照。
class CencPlayerState {
  const CencPlayerState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.isPlaying = false,
    this.playbackState = 1,
    this.readyMs = 0,
    this.drmMode = 'off',
    this.error,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool isPlaying;

  /// ExoPlayer 的 `Player.STATE_*`：1 idle / 2 buffering / 3 ready / 4 ended。
  final int playbackState;

  /// 从 setMedia 到 STATE_READY 花了多少毫秒。
  final int readyMs;

  /// `off` / `clearkey`。
  final String drmMode;

  final String? error;

  bool get isReady => playbackState == 3;

  factory CencPlayerState.fromMap(Map<Object?, Object?> map) => CencPlayerState(
    position: Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
    duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
    buffered: Duration(milliseconds: (map['bufferedMs'] as num?)?.toInt() ?? 0),
    isPlaying: map['isPlaying'] as bool? ?? false,
    playbackState: (map['playbackState'] as num?)?.toInt() ?? 1,
    readyMs: (map['readyMs'] as num?)?.toInt() ?? 0,
    drmMode: map['drmMode'] as String? ?? 'off',
    error: map['error'] as String?,
  );
}

/// 薄插件（`onedrama/cenc_player`）的 Dart 面。
///
/// 纹理 id 交给 `Texture` widget 渲染，其余都是控制调用。控件、手势、锁屏不在
/// 这里——那些归 Flutter 画（见 `docs/adr/0002`）。
class CencPlayer {
  static const MethodChannel _channel = MethodChannel('onedrama/cenc_player');

  int? _textureId;

  bool get isCreated => _textureId != null;

  /// 给 `Texture(textureId: ...)` 用。
  int get textureId =>
      _textureId ?? (throw StateError('先 create() 再取 textureId'));

  /// 这台设备的 MediaDrm 有没有 ClearKey 插件。没有就只能走预解密。
  static Future<bool> clearKeySupported() async =>
      await _channel.invokeMethod<bool>('clearKeySupported') ?? false;

  Future<int> create() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('create');
    _textureId = (result?['textureId'] as num).toInt();
    return _textureId!;
  }

  Future<void> setSurfaceSize(int width, int height) =>
      _channel.invokeMethod<void>('setSurfaceSize', {
        'textureId': _textureId,
        'width': width,
        'height': height,
      });

  /// 设媒体。
  ///
  /// [decryptPlan] 非空时走流式解密数据源——**边下边解，不用先等整集**。
  /// 明文（网页 / 备用源）不传，直接播。
  Future<void> setMedia({
    required String url,
    String? referer,
    Uint8List? cencKey,
    Uint8List? decryptPlan,
  }) => _channel.invokeMethod<void>('setMedia', {
    'textureId': _textureId,
    'url': url,
    'referer': referer,
    'cencKey': cencKey == null ? null : _hex(cencKey),
    'decryptPlan': decryptPlan,
  });

  Future<void> play() =>
      _channel.invokeMethod<void>('play', {'textureId': _textureId});

  Future<void> pause() =>
      _channel.invokeMethod<void>('pause', {'textureId': _textureId});

  Future<void> seekTo(Duration position) => _channel.invokeMethod<void>(
    'seekTo',
    {'textureId': _textureId, 'positionMs': position.inMilliseconds},
  );

  Future<void> setSpeed(double speed) => _channel.invokeMethod<void>(
    'setSpeed',
    {'textureId': _textureId, 'speed': speed},
  );

  /// 音量，0–1。右半屏上下滑动的手势用它。
  Future<void> setVolume(double volume) => _channel.invokeMethod<void>(
    'setVolume',
    {'textureId': _textureId, 'volume': volume.clamp(0.0, 1.0)},
  );

  Future<CencPlayerState> state() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('state', {
      'textureId': _textureId,
    });
    return CencPlayerState.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<void> dispose() async {
    final id = _textureId;
    _textureId = null;
    if (id != null) {
      await _channel.invokeMethod<void>('dispose', {'textureId': id});
    }
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();
