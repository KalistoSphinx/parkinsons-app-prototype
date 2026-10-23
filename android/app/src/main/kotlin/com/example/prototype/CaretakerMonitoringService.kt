package com.example.prototype

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class CaretakerMonitoringService : Service() {
    companion object {
        const val TAG = "CaretakerMonitorSvc"
        const val PREFERENCES = "caretaker_monitoring_prefs"
        const val KEY_ENABLED = "caretaker_enabled"
        const val KEY_RUNNING = "caretaker_running"
        const val KEY_PATIENT_ID = "caretaker_patient_id"
        const val KEY_PATIENT_NAME = "caretaker_patient_name"
        const val KEY_PROCESSING_URL = "caretaker_processing_url"

        const val ACTION_START = "com.example.prototype.CARETAKER_START"
        const val ACTION_STOP = "com.example.prototype.CARETAKER_STOP"
        const val ACTION_SILENCE = "com.example.prototype.CARETAKER_SILENCE"
        const val ACTION_ACKNOWLEDGE = "com.example.prototype.CARETAKER_ACKNOWLEDGE"

        const val EXTRA_PATIENT_ID = "patient_id"
        const val EXTRA_PATIENT_NAME = "patient_name"
        const val EXTRA_PROCESSING_URL = "processing_url"
        const val EXTRA_ALERT_ID = "alert_id"

        private const val ONGOING_NOTIFICATION_ID = 8800

        @Volatile
        var instance: CaretakerMonitoringService? = null
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var scheduler: ScheduledExecutorService? = null
    private var patientId: String = ""
    private var patientName: String = ""
    private var processingUrl: String = ""
    @Volatile private var lastTriggeredAlertId: String? = null
    @Volatile private var isSilencedForAlertId: String? = null

    val isPlaying: Boolean get() = EmergencyNotificationHelper.isAlarmPlaying

    override fun onCreate() {
        super.onCreate()
        instance = this
        EmergencyNotificationHelper.createNotificationChannels(this)
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "prototype:caretaker-monitor")
        wakeLock?.acquire(24 * 60 * 60 * 1000L)
        startForeground(ONGOING_NOTIFICATION_ID, buildOngoingNotification("Initializing live monitoring..."))
        Log.i(TAG, "CaretakerMonitoringService created and foreground started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        Log.i(TAG, "onStartCommand action: $action")
        when (action) {
            ACTION_SILENCE -> {
                silenceAlarmOnly()
                return START_STICKY
            }
            ACTION_ACKNOWLEDGE -> {
                val alertId = intent?.getStringExtra(EXTRA_ALERT_ID) ?: ""
                val pId = intent?.getStringExtra(EXTRA_PATIENT_ID) ?: patientId
                if (alertId.isNotEmpty()) {
                    acknowledgeAlertFromNotification(pId, alertId)
                }
                return START_STICKY
            }
            ACTION_STOP -> {
                stopMonitoring()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val pId = intent?.getStringExtra(EXTRA_PATIENT_ID)
                val pName = intent?.getStringExtra(EXTRA_PATIENT_NAME)
                val pUrl = intent?.getStringExtra(EXTRA_PROCESSING_URL)

                val prefs = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                patientId = pId ?: prefs.getString(KEY_PATIENT_ID, "") ?: ""
                patientName = pName ?: prefs.getString(KEY_PATIENT_NAME, "Patient") ?: "Patient"
                processingUrl = (pUrl ?: prefs.getString(KEY_PROCESSING_URL, "") ?: "").trimEnd('/')

                Log.i(TAG, "Starting caretaker monitoring for patientId=$patientId, url=$processingUrl")

                if (patientId.isEmpty() || processingUrl.isEmpty()) {
                    Log.w(TAG, "Missing patientId or processingUrl; keeping service active and waiting for config")
                    return START_STICKY
                }

                prefs.edit()
                    .putBoolean(KEY_ENABLED, true)
                    .putBoolean(KEY_RUNNING, true)
                    .putString(KEY_PATIENT_ID, patientId)
                    .putString(KEY_PATIENT_NAME, patientName)
                    .putString(KEY_PROCESSING_URL, processingUrl)
                    .apply()

                updateOngoingNotification("Monitoring $patientName • Ready for emergency alerts")
                startPolling()
                return START_STICKY
            }
            else -> return START_STICKY
        }
    }

    private fun startPolling() {
        scheduler?.shutdownNow()
        val exec = Executors.newSingleThreadScheduledExecutor()
        scheduler = exec
        Log.i(TAG, "Background polling scheduled every 3 seconds")
        exec.scheduleWithFixedDelay({
            pollPatientStatus()
        }, 1, 3, TimeUnit.SECONDS)
    }

    private fun pollPatientStatus() {
        if (patientId.isEmpty() || processingUrl.isEmpty()) return
        try {
            val url = URL("$processingUrl/patients/$patientId/active-status")
            val connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 5000
                readTimeout = 5000
            }
            val status = connection.responseCode
            if (status in 200..299) {
                val text = connection.inputStream.bufferedReader().use { it.readText() }
                val obj = JSONObject(text)
                handleStatusResponse(obj)
            }
            connection.disconnect()
        } catch (e: Exception) {
            Log.d(TAG, "Poll status network exception: ${e.message}")
        }
    }

    private fun handleStatusResponse(response: JSONObject) {
        val activeAlert = response.optJSONObject("active_alert")
        if (activeAlert != null) {
            val alertStatus = activeAlert.optString("status", "")
            val alertId = activeAlert.optString("alert_id", "")
            val title = activeAlert.optString("title", "URGENT ALERT")
            val message = activeAlert.optString("message", "Immediate check on patient required.")
            val symptom = activeAlert.optString("symptom", "fall")

            if (alertStatus == "new") {
                Log.i(TAG, "NEW ALERT DETECTED in background: id=$alertId, title=$title")
                val isNewAlert = lastTriggeredAlertId != alertId
                if (isNewAlert) {
                    lastTriggeredAlertId = alertId
                    isSilencedForAlertId = null
                    startAlarm()
                    showEmergencyNotification(alertId, title, message, symptom)
                    MainActivity.notifyCaretakerAlert(activeAlert.toString())
                } else if (!EmergencyNotificationHelper.isAlarmPlaying && isSilencedForAlertId != alertId) {
                    startAlarm()
                }
                return
            }
        }

        // If no active new alert, but alarm/notification was active, stop it
        if (lastTriggeredAlertId != null || EmergencyNotificationHelper.isAlarmPlaying) {
            Log.i(TAG, "Alert resolved/cleared; stopping alarm and notification in background")
            lastTriggeredAlertId = null
            isSilencedForAlertId = null
            stopAlarm()
            cancelEmergencyNotification()
            MainActivity.notifyCaretakerAlertCleared()
        }
    }

    fun startAlarm() {
        EmergencyNotificationHelper.startEmergencyAlarm(this)
    }

    fun silenceAlarmOnly() {
        isSilencedForAlertId = lastTriggeredAlertId
        EmergencyNotificationHelper.stopEmergencyAlarm(this)
    }

    fun stopAlarm() {
        EmergencyNotificationHelper.stopEmergencyAlarm(this)
    }

    private fun acknowledgeAlertFromNotification(pId: String, alertId: String) {
        stopAlarm()
        cancelEmergencyNotification()
        val urlBase = processingUrl
        if (urlBase.isNotEmpty() && pId.isNotEmpty() && alertId.isNotEmpty()) {
            Executors.newSingleThreadExecutor().execute {
                try {
                    val url = URL("$urlBase/patients/$pId/alerts/$alertId/ack")
                    val conn = (url.openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"
                        connectTimeout = 8000
                        readTimeout = 8000
                    }
                    conn.responseCode
                    conn.disconnect()
                    Log.i(TAG, "Acknowledged alert $alertId from notification")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to acknowledge via notification", e)
                }
                MainActivity.notifyCaretakerAlertCleared()
            }
        }
    }

    private fun showEmergencyNotification(
        alertId: String,
        title: String,
        message: String,
        symptom: String
    ) {
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
    }

    private fun cancelEmergencyNotification() {
        EmergencyNotificationHelper.cancelEmergencyNotification(this)
    }

    private fun buildOngoingNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingLaunch = launchIntent?.let {
            PendingIntent.getActivity(this, 1000, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, EmergencyNotificationHelper.ONGOING_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Caretaker Portal Active")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_monitoring)
            .setContentIntent(pendingLaunch)
            .setOngoing(true)
            .build()
    }

    private fun updateOngoingNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(ONGOING_NOTIFICATION_ID, buildOngoingNotification(text))
    }

    private fun stopMonitoring() {
        scheduler?.shutdownNow()
        scheduler = null
        stopAlarm()
        cancelEmergencyNotification()
        val prefs = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_RUNNING, false)
            .apply()
    }

    override fun onDestroy() {
        instance = null
        stopMonitoring()
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
