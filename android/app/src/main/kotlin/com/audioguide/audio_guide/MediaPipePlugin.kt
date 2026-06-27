package com.audioguide.audio_guide

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MediaPipePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var llmInference: LlmInference? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    companion object {
        const val CHANNEL = "com.audioguide/mediapipe"
        const val PROMPT = """<start_of_turn>user
You are an expert audio guide. Analyze this image and write a short audio commentary in French.
3-4 sentences, warm and informative tone, as if speaking to a tourist.
Start directly with what you see, no preamble.
<end_of_turn>
<start_of_turn>model
"""
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        llmInference?.close()
        llmInference = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isModelDownloaded" -> {
                result.success(File(getModelPath()).exists())
            }

            "getModelPath" -> {
                result.success(getModelPath())
            }

            "loadModel" -> {
                scope.launch {
                    try {
                        val options = LlmInference.LlmInferenceOptions.builder()
                            .setModelPath(getModelPath())
                            .setMaxTokens(512)
                            .build()
                        llmInference?.close()
                        llmInference = LlmInference.createFromOptions(context, options)
                        withContext(Dispatchers.Main) { result.success(true) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("LOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "analyzeImage" -> {
                val imagePath = call.argument<String>("imagePath")
                if (imagePath == null) {
                    result.error("INVALID_ARGS", "imagePath required", null)
                    return
                }
                val inference = llmInference
                if (inference == null) {
                    result.error("NOT_INITIALIZED", "Call loadModel first", null)
                    return
                }

                scope.launch {
                    try {
                        // Resize bitmap to reduce memory usage
                        val options = BitmapFactory.Options().apply {
                            inSampleSize = 2
                        }
                        val bitmap = BitmapFactory.decodeFile(imagePath, options)
                            ?: throw Exception("Cannot decode image: $imagePath")

                        val response = inference.generateResponse(PROMPT)
                        bitmap.recycle()

                        withContext(Dispatchers.Main) { result.success(response) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("INFERENCE_ERROR", e.message, null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun getModelPath(): String {
        val dir = context.getExternalFilesDir(null) ?: context.filesDir
        return "${dir.absolutePath}/gemma3-1b-multimodal.task"
    }
}
