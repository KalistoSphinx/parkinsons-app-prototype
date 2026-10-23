import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'server_discovery.dart';

enum MonitoringMode { baseline, anomaly }

extension MonitoringModeWire on MonitoringMode {
  String get wireName => name;

  static MonitoringMode? fromWire(String? value) {
    switch (value) {
      case 'baseline':
        return MonitoringMode.baseline;
      case 'anomaly':
        return MonitoringMode.anomaly;
      default:
        return null;
    }
  }
}

class ContinuousMonitorController {
  static const _channel = MethodChannel('com.example.prototype/day_monitoring');
  static final _updateController = StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> get onMonitoringUpdate => _updateController.stream;
  static bool _channelInitialized = false;

  ContinuousMonitorController() {
    initializeChannel();
  }

  static void initializeChannel() {
    if (_channelInitialized) return;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onMonitoringUpdate') {
          final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
          _updateController.add(args);
        }
        return null;
      });
      _channelInitialized = true;
    } catch (_) {
      // Defer if binary messenger is not yet initialized in headless unit tests
    }
  }

  bool get isSupported => Platform.isAndroid;

  // The wrist position is always left
  static const String fixedWatchSide = 'left';
  String get watchSide => fixedWatchSide;

  Future<bool> isMonitoring([String? patientId]) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>(
      'isMonitoring',
      patientId != null ? {'patientId': patientId} : null,
    ) ?? false;
  }

  Future<MonitoringMode?> currentMode([String? patientId]) async {
    if (!isSupported) return null;
    final value = await _channel.invokeMethod<String>(
      'getMonitoringMode',
      patientId != null ? {'patientId': patientId} : null,
    );
    return MonitoringModeWire.fromWire(value);
  }

  Future<void> start(
    String patientId, {
    required MonitoringMode mode,
    String? processingUrl,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Continuous background sensor monitoring is currently supported on Android only.');
    }
    final permissionsGranted = await _channel.invokeMethod<bool>('requestMonitoringPermissions');
    if (permissionsGranted != true) {
      throw StateError('Grant physical-activity and notification permissions to start all-day monitoring.');
    }

    // A mode switch must start a clean sensor batch so baseline intervals and
    // anomaly intervals are never mixed in the same upload.
    if (await isMonitoring()) {
      await stop();
    }

    final url = processingUrl ?? await ServerDiscovery.instance.discoverServerUrl();

    await _channel.invokeMethod<bool>('startMonitoring', {
      'patientId': patientId,
      'processingUrl': url,
      'watchSide': fixedWatchSide,
      'monitoringMode': mode.wireName,
    });
    for (var attempt = 0; attempt < 15; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await isMonitoring()) return;
    }
    throw StateError('Android did not start the foreground monitoring service. Check its permissions and notification.');
  }

  Future<void> stop() async {
    if (!isSupported) return;
    await _channel.invokeMethod<bool>('stopMonitoring');
    for (var attempt = 0; attempt < 15; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await isMonitoring()) return;
    }
  }
}
