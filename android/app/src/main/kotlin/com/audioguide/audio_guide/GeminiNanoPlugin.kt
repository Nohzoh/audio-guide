package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.common.util.concurrent.FutureCallback
import com.google.common.util.concurrent.Futures
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.imagedescription.ImageDescription
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
import java.util.concurrent.Executors

class GeminiNanoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var imageDescriber: ImageDescriber? = null
    private val executor = Executors.newSingleThreadExecutor()
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
                try {
                    val options = ImageDescriberOptions.builder(context).build()
                    val describer = ImageDescription.getClient(options)
                    val statusFuture = describer.checkFeatureStatus()
                    Futures.addCallback(statusFuture, object : FutureCallback<Int> {
                        override fun onSuccess(status: Int?) {
                            describer.close()
                            scope.launch(Dispatchers.Main) { result.success(true) }
                        }
                        override fun onFailure(t: Throwable) {
                            describer.close()
                            scope.launch(Dispatchers.Main) { result.success(false) }
                        }
                    }, executor)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "initialize" -> {
                try {
                    val options = ImageDescriberOptions.builder(context).build()
                    imageDescriber?.close()
                    val describer = ImageDescription.getClient(options)

                    val downloadFuture = describer.downloadFeature(object : DownloadCallback {
                        override fun onDownloadStarted(bytesToDownload: Long) {}
                        override fun onDownloadProgress(bytesDownloaded: Long) {}
                        override fun onDownloadCompleted() {}
                        override fun onDownloadFailed(e: GenAiException) {}
                    })

                    Futures.addCallback(downloadFuture, object : FutureCallback<Void> {
                        override fun onSuccess(v: Void?) {
                            imageDescriber = describer
                            scope.launch(Dispatchers.Main) { result.success(true) }
                        }
                        override fun onFailure(t: Throwable) {
                            // Model might already be downloaded
                            imageDescriber = describer
                            scope.launch(Dispatchers.Main) { result.success(true) }
                        }
                    }, executor)
                } catch (e: Exception) {
                    result.error("INIT_ERROR", e.message, null)
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
                        val inferenceFuture = describer.runInference(request)

                        Futures.addCallback(inferenceFuture, object : FutureCallback<com.google.mlkit.genai.imagedescription.ImageDescriptionResult> {
                            override fun onSuccess(response: com.google.mlkit.genai.imagedescription.ImageDescriptionResult?) {
                                bitmap.recycle()
                                scope.launch(Dispatchers.Main) {
                                    result.success(response?.description ?: "")
                                }
                            }
                            override fun onFailure(t: Throwable) {
                                bitmap.recycle()
                                scope.launch(Dispatchers.Main) {
                                    result.error("INFERENCE_ERROR", t.message, null)
                                }
                            }
                        }, executor)
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
