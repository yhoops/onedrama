package com.example.onedrama

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

private const val CHANNEL = "onedrama/cenc_player"

/**
 * 薄插件的入口。只注册一个 MethodChannel，不写任何 UI
 * （见 `docs/adr/0002`：Kotlin 只做 ExoPlayer + CENC 解密 + 纹理）。
 */
class MainActivity : FlutterActivity() {
    private val players = mutableMapOf<Long, CencPlayer>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val renderer = flutterEngine.renderer

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handle(call, result, renderer)
                } catch (error: Throwable) {
                    Log.e(CHANNEL, "method ${call.method} failed", error)
                    result.error(CHANNEL, error.message, Log.getStackTraceString(error))
                }
            }
    }

    private fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        renderer: TextureRegistry,
    ) {
        if (call.method == "create") {
            val producer = renderer.createSurfaceProducer()
            players[producer.id()] = CencPlayer(this, producer)
            result.success(mapOf("textureId" to producer.id()))
            return
        }

        val player = playerFor(call)
        if (player == null) {
            result.error(CHANNEL, "没有这个播放器实例", null)
            return
        }

        when (call.method) {
            "setSurfaceSize" -> {
                player.setSurfaceSize(
                    call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0,
                )
                result.success(null)
            }

            "setMedia" -> {
                player.setMedia(
                    url = call.argument<String>("url") ?: error("缺少 url"),
                    referer = call.argument<String>("referer"),
                    cencKeyHex = call.argument<String>("cencKey"),
                    decryptPlan = call.argument<ByteArray>("decryptPlan"),
                )
                result.success(null)
            }

            "play" -> {
                player.play()
                result.success(null)
            }

            "pause" -> {
                player.pause()
                result.success(null)
            }

            "seekTo" -> {
                player.seekTo(call.argument<Number>("positionMs")?.toLong() ?: 0L)
                result.success(null)
            }

            "setSpeed" -> {
                player.setSpeed(call.argument<Number>("speed")?.toFloat() ?: 1f)
                result.success(null)
            }

            "setVolume" -> {
                player.setVolume(call.argument<Number>("volume")?.toFloat() ?: 1f)
                result.success(null)
            }

            "state" -> result.success(player.state())

            "dispose" -> {
                players.remove(call.argument<Number>("textureId")?.toLong())?.release()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun playerFor(call: MethodCall): CencPlayer? =
        players[call.argument<Number>("textureId")?.toLong()]

    override fun onDestroy() {
        players.values.forEach { it.release() }
        players.clear()
        super.onDestroy()
    }
}
