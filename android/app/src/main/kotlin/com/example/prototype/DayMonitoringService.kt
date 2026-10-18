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
    private var patientId = ""
    private var processingUrl = ""
    private var clockOffsetMs = 0L

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
        updateNotification("Monitoring tremor, gait and movement every 3 minutes")
        return START_STICKY
    }

    override fun onSensorChanged(event: SensorEvent) {
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
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun flushIfReady() {
        val batch: Pair<List<Sample>, List<Sample>>
        synchronized(lock) {
            if (uploading || accelerometer.size < MIN_SAMPLES || gyroscope.size < MIN_SAMPLES) return
            val first = minOf(accelerometer.first().timestampMs, gyroscope.first().timestampMs)
            val last = maxOf(accelerometer.last().timestampMs, gyroscope.last().timestampMs)
            if (last - first < MIN_CHUNK_MILLIS && accelerometer.size < MAX_SAMPLES_PER_SENSOR) return
            batch = Pair(accelerometer.toList(), gyroscope.toList())
            accelerometer.clear()
            gyroscope.clear()
            uploading = true
        }
        uploader.execute { upload(batch.first, batch.second) }
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
            responseMessage = if (success) "Movement features saved; today's report refreshed" else "Upload HTTP $status"
            if (!success) android.util.Log.w(TAG, "Monitoring upload rejected ($status): $response")
            connection.disconnect()
        } catch (error: Exception) {
            android.util.Log.e(TAG, "Monitoring upload failed", error)
        } finally {
            synchronized(lock) { uploading = false }
            handler.post { updateNotification(responseMessage) }
            if (success) handler.post { flushIfReady() }
        }
    }

    private fun flushRemainingOnStop() {
        val batch: Pair<List<Sample>, List<Sample>>?
        synchronized(lock) {
            if (!uploading && accelerometer.size >= 100 && gyroscope.size >= 100) {
                val first = minOf(accelerometer.first().timestampMs, gyroscope.first().timestampMs)
                val last = maxOf(accelerometer.last().timestampMs, gyroscope.last().timestampMs)
                if (last - first >= 10_000L) { // Backend requires >= 10 seconds of data
                    batch = Pair(accelerometer.toList(), gyroscope.toList())
                    accelerometer.clear()
                    gyroscope.clear()
                    uploading = true
                } else {
                    batch = null
                }
            } else {
                batch = null
            }
        }
        if (batch != null) {
            try {
                val future = uploader.submit { upload(batch.first, batch.second) }
                future.get(15, java.util.concurrent.TimeUnit.SECONDS)
            } catch (error: Exception) {
                android.util.Log.w(TAG, "Stop flush failed: ${error.message}")
            }
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        sensorManager.unregisterListener(this)
        flushRemainingOnStop()
        synchronized(lock) {
            accelerometer.clear()
            gyroscope.clear()
        }
        if (wakeLock?.isHeld == true) wakeLock?.release()
        getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_RUNNING, false).apply()
        uploader.shutdown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Continuous movement monitoring",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Ongoing sensor monitoring and periodic feature upload" }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
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
            .setSmallIcon(applicationInfo.icon)
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

        private const val CHANNEL_ID = "day_movement_monitoring"
        private const val NOTIFICATION_ID = 7302
        private const val CHUNK_MILLIS = 3 * 60 * 1000L
        private const val MIN_CHUNK_MILLIS = 2 * 60 * 1000L
        private const val MAX_SAMPLES_PER_SENSOR = 12_000
        private const val MIN_SAMPLES = 500
        private const val SENSOR_BATCH_LATENCY_US = 1_000_000
        private const val UPLOAD_TIMEOUT_MILLIS = 240_000
        private const val TAG = "DayMonitoringService"
    }
}
