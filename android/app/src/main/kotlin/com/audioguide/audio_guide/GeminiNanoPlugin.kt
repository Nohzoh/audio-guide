package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadStatus
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

        fun buildSeg1Prompt(locationContext: String?): String {
            val loc = if (!locationContext.isNullOrBlank()) " (prise a : $locationContext)" else ""
            return "Tu es un guide audio culturel. En te basant sur cette image$loc, decris en francais ce que tu vois avec un ton chaleureux et vivant. Commence directement, sans introduction. Ne mentionne pas de dates ou chiffres precis dont tu n'es pas certain. 2-3 phrases maximum."
        }

        fun buildSeg2Prompt(previousText: String): String {
            val excerpt = previousText.takeLast(200)
            return "Tu es un guide audio culturel. Suite de ton commentaire. Texte precedent : "$excerpt". Continue avec le contexte historique et culturel en 2-3 phrases qui s'enchainent naturellement. Pas de repetition."
        }

        fun buildSeg3Prompt(previousText: String): String {
            val excerpt = previousText.takeLast(200)
            return "Tu es un guide audio culturel. Suite de ton commentaire. Texte precedent : "$excerpt". Conclus en 2 phrases sur ce qui rend ce lieu unique et l'emotion qu'il inspire."
        }
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
                        // Use download().collect as per official sample
                        model.download().collect { status ->
                            when (status) {
                                is DownloadStatus.DownloadCompleted -> {
                                    generativeModel = model
                                    withContext(Dispatchers.Main) { result.success(true) }
                                }
                                is DownloadStatus.DownloadFailed -> {
                                    // Model may already be downloaded
                                    generativeModel = model
                                    withContext(Dispatchers.Main) { result.success(true) }
                                }
                                else -> { /* progress */ }
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("INIT_ERROR", e.message, null)
                        }
                    }
                }
            }

            "describeImage" -> {
                val imagePath = call.argument<String>("imagePath")
                val locationContext = call.argument<String>("locationContext")

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

                        // Segment 1: Visual description with image
                        val req1 = generateContentRequest(
                            ImagePart(bitmap),
                            TextPart(buildSeg1Prompt(locationContext))
                        ) { maxOutputTokens = 256 }
                        val seg1 = model.generateContent(req1)
                            .candidates.firstOrNull()?.text?.trim() ?: ""

                        bitmap.recycle()

                        // Segment 2: Historical context (text only, faster)
                        val req2 = generateContentRequest(
                            TextPart(buildSeg2Prompt(seg1))
                        ) { maxOutputTokens = 256 }
                        val seg2 = model.generateContent(req2)
                            .candidates.firstOrNull()?.text?.trim() ?: ""

                        // Segment 3: Conclusion
                        val req3 = generateContentRequest(
                            TextPart(buildSeg3Prompt("$seg1 $seg2"))
                        ) { maxOutputTokens = 256 }
                        val seg3 = model.generateContent(req3)
                            .candidates.firstOrNull()?.text?.trim() ?: ""

                        val fullText = listOf(seg1, seg2, seg3)
                            .filter { it.isNotBlank() }
                            .joinToString(" ")

                        withContext(Dispatchers.Main) { result.success(fullText) }
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
