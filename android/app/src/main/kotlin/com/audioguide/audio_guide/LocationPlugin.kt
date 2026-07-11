package com.audioguide.audio_guide

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.tasks.await

class LocationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    companion object {
        const val CHANNEL = "com.audioguide/location"
        const val PERMISSION_REQUEST_CODE = 1001
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermission" -> {
                val status = getPermissionStatus()
                result.success(status)
            }

            "requestLocation" -> {
                val act = activity
                if (act == null) {
                    result.success(mapOf("status" to "error", "message" to "No activity"))
                    return
                }

                val status = getPermissionStatus()
                when (status) {
                    "deniedForever" -> result.success(mapOf("status" to "deniedForever"))
                    "granted" -> fetchLocation(result)
                    else -> {
                        // Request permission
                        pendingResult = result
                        ActivityCompat.requestPermissions(
                            act,
                            arrayOf(
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION
                            ),
                            PERMISSION_REQUEST_CODE
                        )
                    }
                }
            }

            "openSettings" -> {
                activity?.let {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.fromParts("package", it.packageName, null)
                    }
                    it.startActivity(intent)
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingResult ?: return false
        pendingResult = null

        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            fetchLocation(pending)
        } else {
            val status = getPermissionStatus()
            pending.success(mapOf("status" to status))
        }
        return true
    }

    private fun getPermissionStatus(): String {
        val hasFine = ActivityCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ActivityCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (hasFine || hasCoarse) return "granted"

        val act = activity
        if (act != null && !ActivityCompat.shouldShowRequestPermissionRationale(
                act, Manifest.permission.ACCESS_FINE_LOCATION)) {
            // Check if ever requested before (not first time denial)
            val prefs = context.getSharedPreferences("location_prefs", Context.MODE_PRIVATE)
            if (prefs.getBoolean("permission_requested", false)) {
                return "deniedForever"
            }
        }
        return "denied"
    }

    private fun fetchLocation(result: MethodChannel.Result) {
        scope.launch {
            try {
                val fusedClient = LocationServices.getFusedLocationProviderClient(context)

                // Try last known location first (fast)
                val lastLocation = try {
                    fusedClient.lastLocation.await()
                } catch (_: Exception) { null }

                if (lastLocation != null) {
                    withContext(Dispatchers.Main) {
                        result.success(mapOf(
                            "status" to "granted",
                            "latitude" to lastLocation.latitude,
                            "longitude" to lastLocation.longitude,
                        ))
                    }
                    return@launch
                }

                // Request fresh location
                val locationReq = com.google.android.gms.location.CurrentLocationRequest.Builder()
                    .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                    .setMaxUpdateAgeMillis(10000)
                    .build()

                val location = fusedClient.getCurrentLocation(locationReq, null).await()

                withContext(Dispatchers.Main) {
                    if (location != null) {
                        result.success(mapOf(
                            "status" to "granted",
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                        ))
                    } else {
                        result.success(mapOf("status" to "granted"))
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.success(mapOf("status" to "error", "message" to e.message))
                }
            }
        }
    }
}
