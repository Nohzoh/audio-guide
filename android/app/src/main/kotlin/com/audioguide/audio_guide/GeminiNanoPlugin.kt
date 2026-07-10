package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class GeminiNanoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var generativeModel: GenerativeModel? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    companion object {
        const val CHANNEL = "com.audioguide/gemini_nano"

        const val AUDIO_GUIDE_PROMPT = """Tu es un guide audio culturel expert et passionné. En te basant sur cette image, génère un commentaire audio en français de 3 à 4 phrases, avec un ton chaleureux et vivant, comme si tu t'adressais à un touriste curieux devant toi. Commence directement par ce que tu vois, sans introduction. Sois précis, évocateur et donne un détail historique ou culturel si possible."""
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        generativeModel?.close()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "isAvailable" -> {
                scope.launch {
                    try {
                        val model = Generation.getClient()
                        val status = model.checkStatus()
                        model.close()
                        withContext(Dispatchers.Main) {
                            result.success(status != com.google.mlkit.genai.common.FeatureStatus.UNAVAILABLE)
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.success(false) }
                    }
                }
            }

            "initialize" -> {
                scope.launch {
                    try {
                        generativeModel?.close()
                        val model = Generation.getClient()

                        model.download().collect { status ->
                            when (status) {
                                is DownloadStatus.DownloadCompleted -> {
                                    generativeModel = model
                                    withContext(Dispatchers.Main) { result.success(true) }
                                    return@collect
                                }
                                is DownloadStatus.DownloadFailed -> {
                                    // Model likely already downloaded
                                    generativeModel = model
                                    withContext(Dispatchers.Main) { result.success(true) }
                                    return@collect
                                }
                                else -> { /* continue collecting */ }
                            }
                        }

                        // If download flow completes without explicit signal
                        if (generativeModel == null) {
                            generativeModel = model
                            withContext(Dispatchers.Main) { result.success(true) }
                        }
                    } catch (e: Exception) {
                        // Model may already be ready
                        try {
                            generativeModel = Generation.getClient()
                            withContext(Dispatchers.Main) { result.success(true) }
                        } catch (e2: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("INIT_ERROR", e2.message, null)
                            }
                        }
                    }
                }
            }

            "describeImage" -> {
                val imagePath = call.argument<String>("imagePath")
                if (imagePath == null) {
                    result.error("INVALID_ARGS", "imagePath required", null)
                    return
                }
                val model = generativeModel
                if (model == null) {
                    result.error("NOT_INITIALIZED", "Call initialize first", null)
                    return
                }

                scope.launch {
                    try {
                        val opts = BitmapFactory.Options().apply { inSampleSize = 2 }
                        val bitmap = BitmapFactory.decodeFile(imagePath, opts)
                            ?: throw Exception("Cannot decode image")

                        val request = generateContentRequest(
                            ImagePart(bitmap),
                            TextPart(AUDIO_GUIDE_PROMPT)
                        ) {
                            maxOutputTokens = 256
                        }

                        val response = model.generateContent(request)
                        bitmap.recycle()

                        val text = response.candidates.firstOrNull()?.text ?: ""
                        withContext(Dispatchers.Main) { result.success(text) }
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
}
