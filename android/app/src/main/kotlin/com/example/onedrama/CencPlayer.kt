package com.example.onedrama

import android.content.Context
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.view.TextureRegistry

private const val TAG = "CencPlayer"

/** 与 Dart 侧 client.dart 的 appUserAgent 保持一致。 */
private const val USER_AGENT =
    "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; " +
        "Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 " +
        "QuicVersion:c67e9834 2025-09-08)"

/**
 * 一集的播放器。零 UI：只管 ExoPlayer 实例、纹理输出、CENC 解密数据源。
 * 控件、手势、锁屏都在 Flutter 画（见 `docs/adr/0002`）。
 *
 * 不再有 DRM 那条路——它在真机上被证伪（见 `docs/adr/0005`：提取器解析 NAL 时读到的
 * 是密文，补 pssh、走 ClearKey 都改不了这一点）。现在只有「边下边解」这一条。
 */
class CencPlayer(
    private val context: Context,
    private val producer: TextureRegistry.SurfaceProducer,
) {
    private var player: ExoPlayer? = null
    private var lastError: String? = null
    private var readyMs: Long = 0
    private var startedAt: Long = 0
    private var mode: String = "off"

    val textureId: Long get() = producer.id()

    fun setSurfaceSize(width: Int, height: Int) {
        producer.setSize(width, height)
    }

    /**
     * 设媒体。
     *
     * [decryptPlan] 非空时走流式解密数据源——**边下边解，不用先等整集**，而且任意字节
     * 范围都能从正确的计数器位置起算，所以拖动进度条也没问题。明文（网页 / 备用源）
     * 不传这个参数，直接播。
     */
    fun setMedia(
        url: String,
        referer: String?,
        cencKeyHex: String?,
        decryptPlan: ByteArray?,
    ) {
        releasePlayer()
        lastError = null
        readyMs = 0
        startedAt = System.currentTimeMillis()

        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setConnectTimeoutMs(20_000)
            .setReadTimeoutMs(20_000)
            .setAllowCrossProtocolRedirects(true)
        referer?.takeIf { it.isNotEmpty() }?.let {
            http.setDefaultRequestProperties(mapOf("Referer" to it))
        }
        val upstream: DataSource.Factory = DataSource.Factory { http.createDataSource() }

        val key = cencKeyHex?.takeIf { it.isNotEmpty() }?.let(::hexToBytes)
        mode = if (decryptPlan != null && decryptPlan.isNotEmpty() && key != null) {
            "stream-decrypt"
        } else {
            "off"
        }
        val sourceFactory: DataSource.Factory = if (mode == "stream-decrypt") {
            val plan = DecryptPlan(decryptPlan!!)
            DataSource.Factory {
                CencDecryptDataSource(upstream.createDataSource(), key!!, plan)
            }
        } else {
            upstream
        }

        val mediaSourceFactory =
            DefaultMediaSourceFactory(DefaultDataSource.Factory(context, sourceFactory))

        val exo = ExoPlayer.Builder(context)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY && readyMs == 0L) {
                    readyMs = System.currentTimeMillis() - startedAt
                    Log.i(TAG, "STATE_READY after ${readyMs}ms")
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                lastError = "${error.errorCodeName}: ${error.message}"
                Log.e(TAG, "onPlayerError", error)
            }
        })
        exo.setVideoSurface(producer.surface)
        exo.setMediaItem(MediaItem.fromUri(url))
        exo.prepare()
        player = exo
        Log.i(TAG, "setMedia mode=$mode keyLen=${key?.size ?: 0} url=${url.take(70)}")
    }

    fun play() {
        player?.play()
    }

    fun pause() {
        player?.pause()
    }

    fun seekTo(positionMs: Long) {
        player?.seekTo(positionMs)
    }

    fun setSpeed(speed: Float) {
        player?.setPlaybackSpeed(speed)
    }

    /// 音量。右半屏上下滑动的手势用它。
    fun setVolume(volume: Float) {
        player?.volume = volume.coerceIn(0f, 1f)
    }

    fun state(): Map<String, Any?> {
        val exo = player
        val duration = exo?.duration ?: C.TIME_UNSET
        return mapOf(
            "positionMs" to (exo?.currentPosition ?: 0L),
            "durationMs" to if (duration == C.TIME_UNSET) 0L else duration,
            "bufferedMs" to (exo?.bufferedPosition ?: 0L),
            "isPlaying" to (exo?.isPlaying ?: false),
            "playbackState" to (exo?.playbackState ?: Player.STATE_IDLE),
            "readyMs" to readyMs,
            "drmMode" to mode,
            "error" to lastError,
        )
    }

    fun release() {
        releasePlayer()
        producer.release()
    }

    private fun releasePlayer() {
        player?.release()
        player = null
    }
}

/** 十六进制转字节。Go 那边是 `hex.DecodeString`。 */
internal fun hexToBytes(hex: String): ByteArray {
    val clean = hex.trim()
    val out = ByteArray(clean.length / 2)
    for (index in out.indices) {
        val high = Character.digit(clean[index * 2], 16)
        val low = Character.digit(clean[index * 2 + 1], 16)
        out[index] = ((high shl 4) or low).toByte()
    }
    return out
}
