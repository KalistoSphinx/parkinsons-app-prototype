import 'dart:io';

import 'package:flutter/services.dart';

import 'server_discovery.dart';

class ContinuousMonitorController {
  static const _channel = MethodChannel('com.example.prototype/day_monitoring');

  bool get isSupported => Platform.isAndroid;

  // The wrist position is always left
  static const String fixedWatchSide = 'left';
  String get watchSide => fixedWatchSide;

  Future<bool> isMonitoring() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isMonitoring') ?? false;
  }

  Future<void> start(String patientId, {String? processingUrl}) async {
    if (!isSupported) {
      throw UnsupportedError('Continuous background sensor monitoring is currently supported on Android only.');
    }
    final permissionsGranted = await _channel.invokeMethod<bool>('requestMonitoringPermissions');
    if (permissionsGranted != true) {
      throw StateError('Grant physical-activity and notification permissions to start all-day monitoring.');
    }

    final url = processingUrl ?? await ServerDiscovery.instance.discoverServerUrl();

    await _channel.invokeMethod<bool>('startMonitoring', {
      'patientId': patientId,
      'processingUrl': url,
      'watchSide': fixedWatchSide,
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
