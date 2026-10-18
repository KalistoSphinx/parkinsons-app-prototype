package com.example.prototype

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestMonitoringPermissions" -> requestMonitoringPermissions(result)
                    "startMonitoring" -> {
                        val patientId = call.argument<String>("patientId")
                        val processingUrl = call.argument<String>("processingUrl")
                        val watchSide = call.argument<String>("watchSide") ?: "left"
                        if (patientId.isNullOrBlank() || processingUrl.isNullOrBlank()) {
                            result.error("invalid_config", "Patient and backend URL are required", null)
                            return@setMethodCallHandler
                        }
                        val preferences = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                        preferences.edit()
                            .putBoolean(DayMonitoringService.KEY_ENABLED, true)
                            .putString(DayMonitoringService.KEY_PATIENT_ID, patientId)
                            .putString(DayMonitoringService.KEY_PROCESSING_URL, processingUrl)
                            .putString(DayMonitoringService.KEY_WATCH_SIDE, watchSide)
                            .apply()
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, DayMonitoringService::class.java),
                        )
                        result.success(true)
                    }
                    "stopMonitoring" -> {
                        getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                            .edit().putBoolean(DayMonitoringService.KEY_ENABLED, false).apply()
                        stopService(Intent(this, DayMonitoringService::class.java))
                        result.success(true)
                    }
                    "isMonitoring" -> {
                        val enabled = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                            .getBoolean(DayMonitoringService.KEY_RUNNING, false)
                        result.success(enabled)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestMonitoringPermissions(result: MethodChannel.Result) {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.ACTIVITY_RECOGNITION)
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (needed.isEmpty()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_active", "A monitoring permission request is already open", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, needed.toTypedArray(), MONITORING_PERMISSION_REQUEST)
    }

    @Deprecated("Deprecated in Android")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MONITORING_PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    companion object {
        private const val CHANNEL = "com.example.prototype/day_monitoring"
        private const val MONITORING_PERMISSION_REQUEST = 7303
    }
}
