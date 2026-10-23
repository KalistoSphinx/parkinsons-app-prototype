import 'dart:convert';
import 'package:flutter/services.dart';

class EmergencyAlarmService {
  static const MethodChannel _channel = MethodChannel('com.example.prototype/day_monitoring');

  static final EmergencyAlarmService instance = EmergencyAlarmService._();
  EmergencyAlarmService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  void Function(Map<String, dynamic> alert)? onCaretakerAlertReceived;
  void Function()? onCaretakerAlertDismissed;

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onCaretakerAlert':
        final raw = call.arguments as String?;
        if (raw != null) {
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            _isPlaying = true;
            onCaretakerAlertReceived?.call(map);
          } catch (_) {}
        }
        break;
      case 'onCaretakerAlertCleared':
        _isPlaying = false;
        onCaretakerAlertDismissed?.call();
        break;
    }
  }

  Future<void> startAlarm({
    String alertId = '',
    String title = 'Urgent Alert',
    String message = 'Immediate check on patient required',
    String patientName = 'Patient',
    String symptom = 'fall',
    String patientId = '',
    String processingUrl = '',
  }) async {
    try {
      _isPlaying = true;
      await _channel.invokeMethod('startEmergencyAlarm', {
        'alertId': alertId,
        'title': title,
        'message': message,
        'patientName': patientName,
        'symptom': symptom,
        'patientId': patientId,
        'processingUrl': processingUrl,
      });
    } catch (_) {
      // Platform may fail if not Android
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestMonitoringPermissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopAlarm() async {
    try {
      _isPlaying = false;
      await _channel.invokeMethod('stopEmergencyAlarm');
    } catch (_) {
      // Platform may fail if not Android
    }
  }

  Future<bool> checkIsAlarmPlaying() async {
    try {
      final playing = await _channel.invokeMethod<bool>('isAlarmPlaying') ?? false;
      _isPlaying = playing;
      return playing;
    } catch (_) {
      return false;
    }
  }

  Future<void> startCaretakerMonitoring({
    required String patientId,
    required String patientName,
    required String processingUrl,
  }) async {
    try {
      await _channel.invokeMethod('startCaretakerMonitoring', {
        'patientId': patientId,
        'patientName': patientName,
        'processingUrl': processingUrl,
      });
    } catch (_) {}
  }

  Future<void> stopCaretakerMonitoring() async {
    try {
      await _channel.invokeMethod('stopCaretakerMonitoring');
    } catch (_) {}
  }

  Future<bool> isCaretakerMonitoring() async {
    try {
      return await _channel.invokeMethod<bool>('isCaretakerMonitoring') ?? false;
    } catch (_) {
      return false;
    }
  }
}
