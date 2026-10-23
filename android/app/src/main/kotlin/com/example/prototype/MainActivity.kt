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
    private var channel: MethodChannel? = null
    private var emergencyRingtone: android.media.Ringtone? = null
    private var vibrator: android.os.Vibrator? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        EmergencyNotificationHelper.createNotificationChannels(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestMonitoringPermissions" -> requestMonitoringPermissions(result)
                    "startEmergencyAlarm" -> {
                        val alertId = call.argument<String>("alertId") ?: ""
                        val title = call.argument<String>("title") ?: "Urgent Alert"
                        val message = call.argument<String>("message") ?: "Immediate attention needed"
                        val patientName = call.argument<String>("patientName") ?: "Patient"
                        val symptom = call.argument<String>("symptom") ?: "fall"
                        val patientId = call.argument<String>("patientId") ?: ""
                        val processingUrl = call.argument<String>("processingUrl") ?: ""

                        EmergencyNotificationHelper.startEmergencyAlarm(this)
                        EmergencyNotificationHelper.showEmergencyNotification(
                            this,
                            alertId = alertId,
                            title = title,
                            message = message,
                            patientName = patientName,
                            symptom = symptom,
                            patientId = patientId,
                            processingUrl = processingUrl
                        )
                        result.success(true)
                    }
                    "stopEmergencyAlarm" -> {
                        EmergencyNotificationHelper.stopEmergencyAlarm(this)
                        EmergencyNotificationHelper.cancelEmergencyNotification(this)
                        CaretakerMonitoringService.instance?.silenceAlarmOnly()
                        result.success(true)
                    }
                    "isAlarmPlaying" -> {
                        result.success(EmergencyNotificationHelper.isAlarmPlaying)
                    }
                    "startMonitoring" -> {
                        val patientId = call.argument<String>("patientId")
                        val processingUrl = call.argument<String>("processingUrl")
                        val watchSide = call.argument<String>("watchSide") ?: "left"
                        val monitoringMode = call.argument<String>("monitoringMode") ?: "baseline"
                        if (patientId.isNullOrBlank() || processingUrl.isNullOrBlank()) {
                            result.error("invalid_config", "Patient and backend URL are required", null)
                            return@setMethodCallHandler
                        }
                        if (monitoringMode !in setOf("baseline", "anomaly")) {
                            result.error("invalid_mode", "Monitoring mode must be baseline or anomaly", null)
                            return@setMethodCallHandler
                        }
                        val preferences = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                        preferences.edit()
                            .putBoolean(DayMonitoringService.KEY_ENABLED, true)
                            .putString(DayMonitoringService.KEY_PATIENT_ID, patientId)
                            .putString(DayMonitoringService.KEY_PROCESSING_URL, processingUrl)
                            .putString(DayMonitoringService.KEY_WATCH_SIDE, watchSide)
                            .putString(DayMonitoringService.KEY_MONITORING_MODE, monitoringMode)
                            .apply()
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, DayMonitoringService::class.java),
                        )
                        result.success(true)
                    }
                    "stopMonitoring" -> {
                        val preferences = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                        preferences.edit()
                            .putBoolean(DayMonitoringService.KEY_ENABLED, false)
                            .putBoolean(DayMonitoringService.KEY_RUNNING, false)
                            .remove(DayMonitoringService.KEY_PATIENT_ID)
                            .remove(DayMonitoringService.KEY_MONITORING_MODE)
                            .apply()
                        stopService(Intent(this, DayMonitoringService::class.java))
                        result.success(true)
                    }
                    "isMonitoring" -> {
                        val preferences = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                        val running = preferences.getBoolean(DayMonitoringService.KEY_RUNNING, false) &&
                                      preferences.getBoolean(DayMonitoringService.KEY_ENABLED, false)
                        val activePatientId = preferences.getString(DayMonitoringService.KEY_PATIENT_ID, "") ?: ""
                        val queryPatientId = call.argument<String>("patientId")
                        if (!queryPatientId.isNullOrBlank()) {
                            result.success(running && activePatientId == queryPatientId)
                        } else {
                            result.success(running)
                        }
                    }
                    "getMonitoringMode" -> {
                        val preferences = getSharedPreferences(DayMonitoringService.PREFERENCES, MODE_PRIVATE)
                        val running = preferences.getBoolean(DayMonitoringService.KEY_RUNNING, false) &&
                                      preferences.getBoolean(DayMonitoringService.KEY_ENABLED, false)
                        val activePatientId = preferences.getString(DayMonitoringService.KEY_PATIENT_ID, "") ?: ""
                        val queryPatientId = call.argument<String>("patientId")
                        if (!running || (!queryPatientId.isNullOrBlank() && activePatientId != queryPatientId)) {
                            result.success(null)
                        } else {
                            val mode = preferences.getString(DayMonitoringService.KEY_MONITORING_MODE, null)
                            result.success(mode)
                        }
                    }
                    "startCaretakerMonitoring" -> {
                        val patientId = call.argument<String>("patientId")
                        val patientName = call.argument<String>("patientName") ?: "Patient"
                        val processingUrl = call.argument<String>("processingUrl")
                        if (patientId.isNullOrBlank() || processingUrl.isNullOrBlank()) {
                            result.error("invalid_config", "Patient and backend URL are required", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, CaretakerMonitoringService::class.java).apply {
                            action = CaretakerMonitoringService.ACTION_START
                            putExtra(CaretakerMonitoringService.EXTRA_PATIENT_ID, patientId)
                            putExtra(CaretakerMonitoringService.EXTRA_PATIENT_NAME, patientName)
                            putExtra(CaretakerMonitoringService.EXTRA_PROCESSING_URL, processingUrl)
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    }
                    "stopCaretakerMonitoring" -> {
                        val intent = Intent(this, CaretakerMonitoringService::class.java).apply {
                            action = CaretakerMonitoringService.ACTION_STOP
                        }
                        startService(intent)
                        stopService(Intent(this, CaretakerMonitoringService::class.java))
                        result.success(true)
                    }
                    "isCaretakerMonitoring" -> {
                        val preferences = getSharedPreferences(CaretakerMonitoringService.PREFERENCES, MODE_PRIVATE)
                        val running = preferences.getBoolean(CaretakerMonitoringService.KEY_RUNNING, false) &&
                                      preferences.getBoolean(CaretakerMonitoringService.KEY_ENABLED, false)
                        result.success(running)
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

    private fun startEmergencyAlarm() {
        stopEmergencyAlarm()
        try {
            var alarmUri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM)
            if (alarmUri == null) {
                alarmUri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
            }
            emergencyRingtone = android.media.RingtoneManager.getRingtone(applicationContext, alarmUri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                emergencyRingtone?.isLooping = true
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                emergencyRingtone?.audioAttributes = android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }
            emergencyRingtone?.play()

            val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(android.os.VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(android.os.Vibrator::class.java)
            }
            vibrator = vib
            val pattern = longArrayOf(0, 800, 400, 800, 400, 1200)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vib?.vibrate(android.os.VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vib?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to start emergency alarm", e)
        }
    }

    private fun stopEmergencyAlarm() {
        try {
            if (emergencyRingtone?.isPlaying == true) {
                emergencyRingtone?.stop()
            }
            emergencyRingtone = null
            vibrator?.cancel()
            vibrator = null
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to stop emergency alarm", e)
        }
    }

    override fun onDestroy() {
        EmergencyNotificationHelper.stopEmergencyAlarm(this)
        stopEmergencyAlarm()
        if (instance == this) {
            instance = null
        }
        channel = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "com.example.prototype/day_monitoring"
        private const val MONITORING_PERMISSION_REQUEST = 7303
        @Volatile private var instance: MainActivity? = null

        fun notifyMonitoringUpdate(hasAlert: Boolean, alertJson: String?) {
            val activity = instance ?: return
            activity.runOnUiThread {
                activity.channel?.invokeMethod(
                    "onMonitoringUpdate",
                    mapOf(
                        "hasAlert" to hasAlert,
                        "alert" to alertJson
                    )
                )
            }
        }

        fun notifyCaretakerAlert(alertJson: String) {
            val activity = instance ?: return
            activity.runOnUiThread {
                activity.channel?.invokeMethod("onCaretakerAlert", alertJson)
            }
        }

        fun notifyCaretakerAlertCleared() {
            val activity = instance ?: return
            activity.runOnUiThread {
                activity.channel?.invokeMethod("onCaretakerAlertCleared", null)
            }
        }
    }
}
