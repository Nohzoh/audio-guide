package com.audioguide.audio_guide

import android.media.MediaPlayer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AudioPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var mediaPlayer: MediaPlayer? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.audioguide/audio_player")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        mediaPlayer?.release()
        mediaPlayer = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playWav" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "path required", null)
                    return
                }
                scope.launch {
                    try {
                        mediaPlayer?.stop()
                        mediaPlayer?.release()
                        mediaPlayer = MediaPlayer().apply {
                            setDataSource(path)
                            prepare()
                            start()
                            setOnCompletionListener {
                                scope.launch(Dispatchers.Main) { result.success(null) }
                            }
                            setOnErrorListener { _, _, _ ->
                                scope.launch(Dispatchers.Main) {
                                    result.error("PLAYBACK_ERROR", "Playback failed", null)
                                }
                                true
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("PLAYBACK_ERROR", e.message, null)
                        }
                    }
                }
            }
            "pause" -> { mediaPlayer?.pause(); result.success(null) }
            "stop" -> {
                mediaPlayer?.stop(); mediaPlayer?.release()
                mediaPlayer = null; result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
