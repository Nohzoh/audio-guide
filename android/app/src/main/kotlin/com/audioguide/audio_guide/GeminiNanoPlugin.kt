package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.imagedescription.ImageDescriber
import com.google.mlkit.genai.imagedescription.ImageDescriberOptions
import com.google.mlkit.genai.imagedescription.ImageDescriptionRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class GeminiNanoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var imageDescriber: ImageDescriber? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    companion object {
        const val CHANNEL = "com.audioguide/gemini_nano"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        imageDescriber?.close()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "isAvailable" -> {
                scope.launch {
                    try {
                        val options = ImageDescriberOptions.builder(context).build()
                        val describer = ImageDescriber(options)
                        describer.close()
                        withContext(Dispatchers.Main) { result.success(true) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.success(false) }
                    }
                }
            }

            "initialize" -> {
                scope.launch {
                    try {
                        val options = ImageDescriberOptions.builder(context).build()
                        imageDescriber?.close()
                        val describer = ImageDescriber(options)

                        suspendCancellableCoroutine<Unit> { cont ->
                            describer.downloadFeature(object : DownloadCallback {
                                override fun onDownloadStarted(bytesToDownload: Long) {}
                                override fun onDownloadProgress(bytesDownloaded: Long) {}
                                override fun onDownloadCompleted() {
                                    cont.resume(Unit)
                                }
                                override fun onDownloadFailed(e: GenAiException) {
                                    // Model likely already downloaded, continue anyway
                                    cont.resume(Unit)
                                }
                            })
                        }

                        imageDescriber = describer
                        withContext(Dispatchers.Main) { result.success(true) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("INIT_ERROR", e.message, null)
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
                val describer = imageDescriber
                if (describer == null) {
                    result.error("NOT_INITIALIZED", "Call initialize first", null)
                    return
                }

                scope.launch {
                    try {
                        val opts = BitmapFactory.Options().apply { inSampleSize = 2 }
                        val bitmap = BitmapFactory.decodeFile(imagePath, opts)
                            ?: throw Exception("Cannot decode image")

                        val request = ImageDescriptionRequest.builder(bitmap).build()

                        val description = suspendCancellableCoroutine<String> { cont ->
                            describer.runInference(request)
                                .addOnSuccessListener { response ->
                                    cont.resume(response.description)
                                }
                                .addOnFailureListener { e ->
                                    cont.resumeWithException(e)
                                }
                        }

                        bitmap.recycle()
                        withContext(Dispatchers.Main) { result.success(description) }
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
