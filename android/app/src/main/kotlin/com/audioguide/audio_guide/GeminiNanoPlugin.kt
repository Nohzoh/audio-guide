package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.DownloadStatus
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
import kotlinx.coroutines.tasks.await

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
                        val describer = ImageDescriber.createImageDescriber(options)
                        val status = describer.checkFeatureStatus().await()
                        describer.close()
                        withContext(Dispatchers.Main) {
                            result.success(
                                status == DownloadStatus.DOWNLOADED ||
                                status == DownloadStatus.DOWNLOADABLE
                            )
                        }
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
                        imageDescriber = ImageDescriber.createImageDescriber(options)

                        val status = imageDescriber!!.checkFeatureStatus().await()

                        if (status == DownloadStatus.DOWNLOADABLE) {
                            // Trigger model download
                            imageDescriber!!.downloadFeature(object : DownloadCallback {
                                override fun onDownloadStarted(bytesToDownload: Long) {}
                                override fun onDownloadProgress(bytesDownloaded: Long, bytesToDownload: Long) {}
                                override fun onDownloadFailed(e: Exception) {
                                    scope.launch(Dispatchers.Main) {
                                        result.error("DOWNLOAD_FAILED", e.message, null)
                                    }
                                }
                                override fun onDownloadCompleted() {
                                    scope.launch(Dispatchers.Main) { result.success(true) }
                                }
                            })
                        } else if (status == DownloadStatus.DOWNLOADED) {
                            withContext(Dispatchers.Main) { result.success(true) }
                        } else {
                            withContext(Dispatchers.Main) {
                                result.error("NOT_AVAILABLE", "Gemini Nano not available", null)
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
                        val bitmap = BitmapFactory.decodeFile(imagePath)
                            ?: throw Exception("Cannot decode image")

                        val request = ImageDescriptionRequest.builder(bitmap).build()
                        val description = describer.runInference(request).await()
                        bitmap.recycle()

                        withContext(Dispatchers.Main) {
                            result.success(description.description)
                        }
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
