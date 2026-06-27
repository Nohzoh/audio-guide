package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
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
        const val PROMPT_TEMPLATE = """You are an expert audio guide. 
Analyze this image and generate a short, engaging audio commentary in French.
Keep it to 3-4 sentences, warm and informative tone, as if speaking to a tourist.
Start directly with what you see, no preamble."""
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        llmInference?.close()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isModelDownloaded" -> {
                val modelPath = getModelPath()
                result.success(File(modelPath).exists())
            }

            "loadModel" -> {
                val modelPath = getModelPath()
                scope.launch {
                    try {
                        val options = LlmInference.LlmInferenceOptions.builder()
                            .setModelPath(modelPath)
                            .setMaxTokens(512)
                            .setTopK(40)
                            .setTemperature(0.8f)
                            .setRandomSeed(42)
                            .build()
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
                    result.error("INVALID_ARGS", "imagePath is required", null)
                    return
                }

                val inference = llmInference
                if (inference == null) {
                    result.error("NOT_INITIALIZED", "Model not loaded", null)
                    return
                }

                scope.launch {
                    try {
                        val bitmap = BitmapFactory.decodeFile(imagePath)
                            ?: throw Exception("Cannot decode image")

                        val session = LlmInferenceSession.createFromOptions(
                            inference,
                            LlmInferenceSession.LlmInferenceSessionOptions.builder()
                                .setTopK(40)
                                .setTemperature(0.8f)
                                .build()
                        )

                        session.addQueryChunk(PROMPT_TEMPLATE)
                        session.addImage(bitmap)

                        val response = session.generateResponse()
                        session.close()

                        withContext(Dispatchers.Main) { result.success(response) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("INFERENCE_ERROR", e.message, null)
                        }
                    }
                }
            }

            "getModelPath" -> result.success(getModelPath())

            else -> result.notImplemented()
        }
    }

    private fun getModelPath(): String {
        val dir = context.getExternalFilesDir(null) ?: context.filesDir
        return "${dir.absolutePath}/gemma3-1b-multimodal.task"
    }
}
