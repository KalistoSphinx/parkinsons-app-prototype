package com.example.prototype

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class EmergencyActionReceiver : BroadcastReceiver() {
    companion object {
        const val TAG = "EmergencyActionReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        when (action) {
            EmergencyNotificationHelper.ACTION_SILENCE -> {
                EmergencyNotificationHelper.stopEmergencyAlarm(context)
                CaretakerMonitoringService.instance?.silenceAlarmOnly()
            }
            EmergencyNotificationHelper.ACTION_ACKNOWLEDGE -> {
                val alertId = intent.getStringExtra(EmergencyNotificationHelper.EXTRA_ALERT_ID) ?: ""
                var patientId = intent.getStringExtra(EmergencyNotificationHelper.EXTRA_PATIENT_ID) ?: ""
                var processingUrl = intent.getStringExtra(EmergencyNotificationHelper.EXTRA_PROCESSING_URL) ?: ""

                val prefs = context.getSharedPreferences(CaretakerMonitoringService.PREFERENCES, Context.MODE_PRIVATE)
                if (patientId.isEmpty()) {
                    patientId = prefs.getString(CaretakerMonitoringService.KEY_PATIENT_ID, "") ?: ""
                }
                if (processingUrl.isEmpty()) {
                    processingUrl = prefs.getString(CaretakerMonitoringService.KEY_PROCESSING_URL, "") ?: ""
                }

                EmergencyNotificationHelper.stopEmergencyAlarm(context)
                EmergencyNotificationHelper.cancelEmergencyNotification(context)
                CaretakerMonitoringService.instance?.silenceAlarmOnly()

                if (alertId.isNotEmpty() && patientId.isNotEmpty() && processingUrl.isNotEmpty()) {
                    Executors.newSingleThreadExecutor().execute {
                        try {
                            val url = URL("$processingUrl/patients/$patientId/alerts/$alertId/ack")
                            val conn = (url.openConnection() as HttpURLConnection).apply {
                                requestMethod = "POST"
                                connectTimeout = 8000
                                readTimeout = 8000
                            }
                            conn.responseCode
                            conn.disconnect()
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to acknowledge via notification action", e)
                        }
                        MainActivity.notifyCaretakerAlertCleared()
                    }
                }
            }
        }
    }
}
