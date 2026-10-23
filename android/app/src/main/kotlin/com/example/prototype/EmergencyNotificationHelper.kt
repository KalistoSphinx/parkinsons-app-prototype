package com.example.prototype

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

object EmergencyNotificationHelper {
    const val TAG = "EmergencyHelper"
    const val ONGOING_CHANNEL_ID = "caretaker_monitoring_ongoing"
    const val ALERT_CHANNEL_ID = "caretaker_emergency_alerts_v5"
    const val ONGOING_NOTIFICATION_ID = 8800
    const val ALERT_NOTIFICATION_ID = 8801

    const val ACTION_SILENCE = "com.example.prototype.ACTION_SILENCE_ALARM"
    const val ACTION_ACKNOWLEDGE = "com.example.prototype.ACTION_ACKNOWLEDGE_ALARM"
    const val EXTRA_ALERT_ID = "alert_id"
    const val EXTRA_PATIENT_ID = "patient_id"
    const val EXTRA_PROCESSING_URL = "processing_url"

    private var mediaPlayer: MediaPlayer? = null
    private var emergencyRingtone: Ringtone? = null
    private var toneGenerator: ToneGenerator? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile var isAlarmPlaying: Boolean = false
        private set

    fun getSystemAlarmUri(context: Context): Uri {
        val appContext = context.applicationContext

        // 1. Query the actual default alarm URI configured in the user's system settings
        try {
            val alarmUri = RingtoneManager.getActualDefaultRingtoneUri(appContext, RingtoneManager.TYPE_ALARM)
            if (alarmUri != null) {
                Log.d(TAG, "Resolved system alarm URI: $alarmUri")
                return alarmUri
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to resolve actual default alarm URI", e)
        }

        // 2. Query RingtoneManager cursor for the device's first available alarm sound
        try {
            val rm = RingtoneManager(appContext).apply {
                setType(RingtoneManager.TYPE_ALARM)
            }
            val cursor = rm.cursor
            if (cursor != null && cursor.moveToFirst()) {
                val uri = rm.getRingtoneUri(0)
                if (uri != null) {
                    Log.d(TAG, "Resolved alarm URI from cursor: $uri")
                    return uri
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query system alarm ringtones", e)
        }

        // 3. Fallback to standard system default alarm alert URI
        return RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: android.provider.Settings.System.DEFAULT_ALARM_ALERT_URI
    }

    fun createNotificationChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Clean up old channel versions
            try {
                manager.deleteNotificationChannel("caretaker_emergency_alerts_v1")
                manager.deleteNotificationChannel("caretaker_emergency_alerts_v2")
                manager.deleteNotificationChannel("caretaker_emergency_alerts_v3")
                manager.deleteNotificationChannel("caretaker_emergency_alerts_v4")
            } catch (_: Exception) {}

            val ongoing = NotificationChannel(
                ONGOING_CHANNEL_ID,
                "Caretaker Live Monitoring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps caretaker emergency monitoring active in background"
                setShowBadge(false)
            }

            // Set sound to null so SystemUI doesn't play a call ringtone or notification chime over our alarm
            val alerts = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Patient Emergency Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "High-priority alarm notifications when patient needs immediate attention"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 1200)
                enableLights(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setBypassDnd(true)
                }
            }
            manager.createNotificationChannel(ongoing)
            manager.createNotificationChannel(alerts)
        }
    }

    @Synchronized
    fun startEmergencyAlarm(context: Context) {
        if (isAlarmPlaying) {
            Log.d(TAG, "Emergency alarm is already playing")
            return
        }
        isAlarmPlaying = true
        val appContext = context.applicationContext
        Log.i(TAG, "Starting phone normal alarm ringtone at default volume")

        // 1. Wake up the screen if locked/asleep
        try {
            val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "prototype:EmergencyAlarmWakeLock"
            )
            wakeLock?.acquire(15000)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire screen wake lock", e)
        }

        // 2. Play the phone normal alarm ringtone (at device default alarm volume)
        val alarmUri = getSystemAlarmUri(appContext)
        var soundStarted = false

        try {
            val player = MediaPlayer()
            player.setDataSource(appContext, alarmUri)
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                    .build()
            )
            player.isLooping = true
            player.prepare()
            player.start()
            mediaPlayer = player
            soundStarted = true
            Log.i(TAG, "Playing phone normal alarm ringtone via MediaPlayer: $alarmUri")
        } catch (e: Exception) {
            Log.w(TAG, "MediaPlayer failed with alarmUri, falling back to RingtoneManager", e)
        }

        // Fallback A: RingtoneManager
        if (!soundStarted) {
            try {
                val r = RingtoneManager.getRingtone(appContext, alarmUri)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    r.isLooping = true
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    r.audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                        .build()
                }
                r.play()
                emergencyRingtone = r
                soundStarted = true
                Log.i(TAG, "Playing phone normal alarm ringtone via RingtoneManager: $alarmUri")
            } catch (e: Exception) {
                Log.w(TAG, "RingtoneManager fallback failed", e)
            }
        }

        // Fallback B: ToneGenerator hardware beeper
        if (!soundStarted) {
            try {
                val tg = ToneGenerator(AudioManager.STREAM_ALARM, 100)
                tg.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, 30000)
                toneGenerator = tg
                Log.i(TAG, "ToneGenerator fallback started")
            } catch (e: Exception) {
                Log.e(TAG, "All audio alarm mechanisms failed", e)
            }
        }

        // 3. Start continuous vibration pattern
        try {
            val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = appContext.getSystemService(VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                appContext.getSystemService(Vibrator::class.java)
            }
            vibrator = vib
            val pattern = longArrayOf(0, 800, 400, 800, 400, 1200)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vib?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vib?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start vibrator", e)
        }
    }

    @Synchronized
    fun stopEmergencyAlarm(context: Context) {
        Log.i(TAG, "Stopping emergency alarm sound and vibration")
        isAlarmPlaying = false
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
            mediaPlayer = null
        } catch (_: Exception) {}
        try {
            emergencyRingtone?.stop()
            emergencyRingtone = null
        } catch (_: Exception) {}
        try {
            toneGenerator?.stopTone()
            toneGenerator?.release()
            toneGenerator = null
        } catch (_: Exception) {}
        try {
            vibrator?.cancel()
            vibrator = null
        } catch (_: Exception) {}
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
        } catch (_: Exception) {}
    }

    fun showEmergencyNotification(
        context: Context,
        alertId: String,
        title: String,
        message: String,
        patientName: String,
        symptom: String,
        patientId: String = "",
        processingUrl: String = ""
    ) {
        createNotificationChannels(context)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val prefs = context.getSharedPreferences(CaretakerMonitoringService.PREFERENCES, Context.MODE_PRIVATE)
        val effectivePatientId = patientId.ifEmpty { prefs.getString(CaretakerMonitoringService.KEY_PATIENT_ID, "") ?: "" }
        val effectiveUrl = processingUrl.ifEmpty { prefs.getString(CaretakerMonitoringService.KEY_PROCESSING_URL, "") ?: "" }
        val effectivePatientName = patientName.ifEmpty { prefs.getString(CaretakerMonitoringService.KEY_PATIENT_NAME, "Patient") ?: "Patient" }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("route", "/caretaker")
            putExtra("alert_id", alertId)
        }
        val pendingLaunch = launchIntent?.let {
            PendingIntent.getActivity(context, 2001, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        val silenceIntent = Intent(context, EmergencyActionReceiver::class.java).apply {
            action = ACTION_SILENCE
        }
        val pendingSilence = PendingIntent.getBroadcast(
            context,
            2002,
            silenceIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val ackIntent = Intent(context, EmergencyActionReceiver::class.java).apply {
            action = ACTION_ACKNOWLEDGE
            putExtra(EXTRA_ALERT_ID, alertId)
            putExtra(EXTRA_PATIENT_ID, effectivePatientId)
            putExtra(EXTRA_PROCESSING_URL, effectiveUrl)
        }
        val pendingAck = PendingIntent.getBroadcast(
            context,
            2003,
            ackIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val isFall = symptom == "fall" || title.lowercase().contains("fall")
        val alertHeader = if (isFall) "EMERGENCY: FALL DETECTED" else "URGENT PATIENT ALERT"
        val alertBody = if (effectivePatientName.isNotEmpty()) "$title for $effectivePatientName\n$message" else "$title\n$message"

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, ALERT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        val notification = builder
            .setContentTitle(alertHeader)
            .setContentText(alertBody)
            .setSmallIcon(R.drawable.ic_stat_emergency)
            .setContentIntent(pendingLaunch)
            .setFullScreenIntent(pendingLaunch, true)
            .setAutoCancel(false)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_MAX)
            .setCategory(Notification.CATEGORY_ALARM)
            .setStyle(Notification.BigTextStyle().bigText(alertBody))
            .addAction(Notification.Action.Builder(null, "Silence", pendingSilence).build())
            .addAction(Notification.Action.Builder(null, "Acknowledge", pendingAck).build())
            .build()

        try {
            manager.notify(ALERT_NOTIFICATION_ID, notification)
            Log.i(TAG, "Successfully posted emergency notification: id=$ALERT_NOTIFICATION_ID, title=$alertHeader")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post emergency notification", e)
        }
    }

    fun cancelEmergencyNotification(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.cancel(ALERT_NOTIFICATION_ID)
            Log.i(TAG, "Cancelled emergency notification id=$ALERT_NOTIFICATION_ID")
        } catch (_: Exception) {}
    }
}
