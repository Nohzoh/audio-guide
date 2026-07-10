package com.audioguide.audio_guide

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadCallback
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
                        val featureStatus = describer.checkFeatureStatus()
                        describer.close()
                        withContext(Dispatchers.Main) {
                            result.success(featureStatus != null)
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
                        val describer = ImageDescriber.createImageDescriber(options)

                        describer.downloadFeature(object : DownloadCallback {
                            override fun onDownloadStarted(bytesToDownload: Long) {}
                            override fun onDownloadProgress(bytesDownloaded: Long) {}
                            override fun onDownloadCompleted() {
                                imageDescriber = describer
                                scope.launch(Dispatchers.Main) { result.success(true) }
                            }
                            override fun onDownloadFailed(e: Exception) {
                                // Model might already be downloaded, try using it anyway
                                imageDescriber = describer
                                scope.launch(Dispatchers.Main) { result.success(true) }
                            }
                        })
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
                        val options = BitmapFactory.Options().apply { inSampleSize = 2 }
                        val bitmap = BitmapFactory.decodeFile(imagePath, options)
                            ?: throw Exception("Cannot decode image")

                        val request = ImageDescriptionRequest.builder(bitmap).build()
                        val task = describer.runInference(request)

                        // Poll for result
                        var attempts = 0
                        while (!task.isComplete && attempts < 60) {
                            kotlinx.coroutines.delay(500)
                            attempts++
                        }

                        bitmap.recycle()

                        if (task.isSuccessful) {
                            val description = task.result?.description ?: ""
                            withContext(Dispatchers.Main) { result.success(description) }
                        } else {
                            throw Exception(task.exception?.message ?: "Inference failed")
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
