package com.example.prototype

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

/** Android foreground IMU collector. Raw samples exist only in bounded RAM batches. */
class DayMonitoringService : Service(), SensorEventListener {
    private data class Sample(val timestampMs: Long, val x: Float, val y: Float, val z: Float) {
        fun json(): JSONObject = JSONObject()
            .put("timestamp_ms", timestampMs)
            .put("x", x.toDouble())
            .put("y", y.toDouble())
            .put("z", z.toDouble())
    }

    private val lock = Any()
    private val accelerometer = ArrayList<Sample>()
    private val gyroscope = ArrayList<Sample>()
    private val handler = Handler(Looper.getMainLooper())
    private val uploader = Executors.newSingleThreadExecutor()
    private lateinit var sensorManager: SensorManager
    private var wakeLock: PowerManager.WakeLock? = null
    private var uploading = false
    private var watchSide = "left"
    @Volatile private var monitoringMode = MONITORING_MODE_BASELINE
    private var patientId = ""
    private var processingUrl = ""
    private var clockOffsetMs = 0L

    // On-device severe impact early-flush trigger:
    private var lastFreeFallTimestampMs = 0L
    private var lastImpactTimestampMs = 0L
    private var lastImpactG = 0f
    private var lastFallDetectedTimeMs = 0L

    private val flushRunnable = object : Runnable {
        override fun run() {
            flushIfReady()
            handler.postDelayed(this, CHUNK_MILLIS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("Collecting wrist motion for today's report"))
        clockOffsetMs = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "prototype:day-monitor")
        wakeLock?.acquire()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val preferences = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(KEY_ENABLED, false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        patientId = preferences.getString(KEY_PATIENT_ID, "") ?: ""
        processingUrl = (preferences.getString(KEY_PROCESSING_URL, "") ?: "").trimEnd('/')
        watchSide = "left" // Always left wrist

        val requestedMode = preferences.getString(KEY_MONITORING_MODE, MONITORING_MODE_BASELINE)
            ?: MONITORING_MODE_BASELINE
        if (requestedMode != monitoringMode) {
            // Never mix baseline-building samples with anomaly-monitoring samples.
            synchronized(lock) {
                accelerometer.clear()
                gyroscope.clear()
            }
            monitoringMode = requestedMode
        }

        val accel = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val gyro = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        if (accel == null || gyro == null || patientId.isBlank() || processingUrl.isBlank()) {
            updateNotification("Required sensors or monitoring settings are unavailable")
            preferences.edit().putBoolean(KEY_ENABLED, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        sensorManager.registerListener(this, accel, SensorManager.SENSOR_DELAY_GAME, SENSOR_BATCH_LATENCY_US)
        sensorManager.registerListener(this, gyro, SensorManager.SENSOR_DELAY_GAME, SENSOR_BATCH_LATENCY_US)
        preferences.edit().putBoolean(KEY_RUNNING, true).apply()
        handler.removeCallbacks(flushRunnable)
        handler.postDelayed(flushRunnable, CHUNK_MILLIS)
        updateNotification(
            if (monitoringMode == MONITORING_MODE_BASELINE) {
                "Building personal baseline every 20 seconds"
            } else {
                "Monitoring for changes against the personal baseline"
            }
        )
        return START_STICKY
    }

    override fun onSensorChanged(event: SensorEvent) {
        val preferences = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(KEY_ENABLED, false)) return

        val sample = Sample(
            timestampMs = clockOffsetMs + event.timestamp / 1_000_000L,
            x = event.values[0],
            y = event.values[1],
            z = event.values[2],
        )
        synchronized(lock) {
            val destination = if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) accelerometer else gyroscope
            if (destination.size < MAX_SAMPLES_PER_SENSOR) destination.add(sample)
        }

        // If a high deceleration shock (>= 3.2g) occurs following weightlessness free-fall,
        // trigger an early flush so the server's biomechanical detector can evaluate immediately.
        val nowMs = sample.timestampMs
        if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
            val ax = event.values[0] / 9.80665f
            val ay = event.values[1] / 9.80665f
            val az = event.values[2] / 9.80665f
            val aMag = Math.sqrt((ax * ax + ay * ay + az * az).toDouble()).toFloat()

            if (aMag < 0.50f) {
                lastFreeFallTimestampMs = nowMs
            }

            if (aMag >= 3.2f && (nowMs - lastFreeFallTimestampMs) in 40L..800L) {
                if (nowMs - lastImpactTimestampMs > 5000L) {
                    lastImpactTimestampMs = nowMs
                    lastImpactG = aMag
                }
            }

            if (lastImpactTimestampMs > 0L && (nowMs - lastImpactTimestampMs) in 1500L..2500L) {
                if (nowMs - lastFallDetectedTimeMs > 20_000L) {
                    lastFallDetectedTimeMs = nowMs
                    android.util.Log.i(TAG, "Potential severe impact detected (${lastImpactG}g). Triggering early flush for server evaluation.")
                    handler.post { flushIfReady(forceEarly = true) }
                }
                lastImpactTimestampMs = 0L
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun flushIfReady(forceEarly: Boolean = false) {
        val preferences = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(KEY_ENABLED, false)) return

        val batch: Pair<List<Sample>, List<Sample>>?
        synchronized(lock) {
            if (uploading || accelerometer.size < MIN_SAMPLES || gyroscope.size < MIN_SAMPLES) return
            val first = minOf(accelerometer.first().timestampMs, gyroscope.first().timestampMs)
            val last = maxOf(accelerometer.last().timestampMs, gyroscope.last().timestampMs)
            val duration = last - first
            val minDuration = if (forceEarly) 12_000L else MIN_CHUNK_MILLIS
            if (duration < minDuration && accelerometer.size < MAX_SAMPLES_PER_SENSOR) {
                if (forceEarly && duration < 12_000L) {
                    val remaining = 12_000L - duration
                    handler.postDelayed({ flushIfReady(forceEarly = true) }, remaining)
                }
                return
            }
            batch = Pair(accelerometer.toList(), gyroscope.toList())
            accelerometer.clear()
            gyroscope.clear()
            uploading = true
        }
        if (batch != null) {
            uploader.execute { upload(batch.first, batch.second) }
        }
    }

    private fun upload(accel: List<Sample>, gyro: List<Sample>) {
        var success = false
        var responseMessage = "Upload failed; monitoring continues"
        try {
            val start = minOf(accel.first().timestampMs, gyro.first().timestampMs)
            val end = maxOf(accel.last().timestampMs, gyro.last().timestampMs)
            val localDate = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(end))
            val payload = JSONObject()
                .put("task_type", "monitoring")
                .put("monitoring_mode", monitoringMode)
                .put("patient_id", patientId)
                .put("session_id", UUID.randomUUID().toString())
                .put("watch_side", watchSide)
                .put("start_time_ms", start)
                .put("timestamp_ms", end)
                .put("local_date", localDate)
                .put("accelerometer", JSONArray().apply { accel.forEach { put(it.json()) } })
                .put("gyroscope", JSONArray().apply { gyro.forEach { put(it.json()) } })

            val connection = (URL("$processingUrl/process-session").openConnection() as HttpURLConnection)
            connection.requestMethod = "POST"
            connection.connectTimeout = 20_000
            connection.readTimeout = UPLOAD_TIMEOUT_MILLIS
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val response = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
            success = status in 200..299
            val responseObj = if (success) runCatching { JSONObject(response) }.getOrNull() else null
            val serverMode = responseObj?.optString("monitoring_mode")
            if (!serverMode.isNullOrEmpty() && serverMode != monitoringMode) {
                monitoringMode = serverMode
                getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                    .edit()
                    .putString(KEY_MONITORING_MODE, serverMode)
                    .apply()
            }
            val alert = if (success) {
                responseObj?.optJSONObject("alert")
            } else {
                android.util.Log.w(TAG, "Monitoring upload rejected ($status): $response")
                null
            }
            responseMessage = when {
                !success -> "Upload HTTP $status"
                monitoringMode == MONITORING_MODE_BASELINE -> "Baseline interval saved"
                alert != null -> "Change detected; open the app for details"
                else -> "Movement features saved; no alert"
            }
            // Patient profile should not receive system alert notifications.
            // Notifications are delivered to the caretaker profile.
            if (success) {
                MainActivity.notifyMonitoringUpdate(alert != null, alert?.toString())
            }
            connection.disconnect()
        } catch (error: Exception) {
            android.util.Log.e(TAG, "Monitoring upload failed", error)
        } finally {
            synchronized(lock) { uploading = false }
            handler.post { updateNotification(responseMessage) }
            val preferences = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (success && preferences.getBoolean(KEY_ENABLED, false)) {
                handler.post { flushIfReady() }
            }
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        sensorManager.unregisterListener(this)
        synchronized(lock) {
            accelerometer.clear()
            gyroscope.clear()
        }
        if (wakeLock?.isHeld == true) wakeLock?.release()
        getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_RUNNING, false)
            .remove(KEY_PATIENT_ID)
            .remove(KEY_MONITORING_MODE)
            .apply()
        uploader.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ongoing = NotificationChannel(
                CHANNEL_ID,
                "Continuous movement monitoring",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Ongoing sensor monitoring and periodic feature upload" }
            val alerts = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Movement change alerts",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerts when movement differs from the personal baseline"
                enableVibration(true)
                enableLights(true)
            }
            manager.createNotificationChannel(ongoing)
            manager.createNotificationChannel(alerts)
        }
    }

    private fun showAlertNotification(alert: JSONObject) {
        val severity = alert.optString("severity", "warning")
        val alertId = alert.optString("alert_id", UUID.randomUUID().toString())
        val title = if (severity == "critical") {
            "Urgent movement change detected"
        } else {
            "Movement change detected"
        }
        // Keep clinical details off the lock screen. The app shows the full
        // alert after the user opens it.
        val message = "An unusual pattern was detected relative to the personal baseline. Tap for details."
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, ALERT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_stat_monitoring)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setPriority(Notification.PRIORITY_HIGH)
            .setOnlyAlertOnce(false)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .build()
        val notificationId = ALERT_NOTIFICATION_ID_BASE +
            (alertId.hashCode() and 0x7fffffff) % 100000
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(notificationId, notification)
    }

    private fun notification(message: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Parkinson's movement monitoring")
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_stat_monitoring)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun updateNotification(message: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, notification(message))
    }

    companion object {
        const val PREFERENCES = "continuous_monitoring"
        const val KEY_ENABLED = "enabled"
        const val KEY_RUNNING = "running"
        const val KEY_PATIENT_ID = "patient_id"
        const val KEY_PROCESSING_URL = "processing_url"
        const val KEY_WATCH_SIDE = "watch_side"
        const val KEY_MONITORING_MODE = "monitoring_mode"
        const val MONITORING_MODE_BASELINE = "baseline"
        const val MONITORING_MODE_ANOMALY = "anomaly"

        private const val CHANNEL_ID = "day_movement_monitoring"
        private const val ALERT_CHANNEL_ID = "movement_change_alerts"
        private const val NOTIFICATION_ID = 7302
        private const val ALERT_NOTIFICATION_ID_BASE = 7400
        private const val CHUNK_MILLIS = 20 * 1000L
        private const val MIN_CHUNK_MILLIS = 15 * 1000L
        private const val MAX_SAMPLES_PER_SENSOR = 12_000
        private const val MIN_SAMPLES = 500
        private const val SENSOR_BATCH_LATENCY_US = 1_000_000
        private const val UPLOAD_TIMEOUT_MILLIS = 90_000
        private const val TAG = "DayMonitoringService"
    }
}
