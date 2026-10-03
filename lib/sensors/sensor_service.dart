import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'window_buffer.dart';

class SensorService {
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  
  final WindowBuffer buffer;
  final Function(WindowBuffer) onWindowFull;
  
  bool _isRunning = false;

  SensorService({
    required int windowDurationMs,
    required this.onWindowFull,
  }) : buffer = WindowBuffer(windowDurationMs: windowDurationMs);

  bool get isRunning => _isRunning;

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    buffer.clear();
    
    // Using userAccelerometerEvents to exclude gravity if possible, 
    // but standard accelerometerEvents is fine if we remove DC offset ourselves.
    // Let's use accelerometerEvents and do manual DC offset removal.
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!_isRunning) return;
      
      buffer.addAccelSample(SensorSample(event.x, event.y, event.z, DateTime.now()));
      _checkBuffer();
    });

    _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (!_isRunning) return;
      
      buffer.addGyroSample(SensorSample(event.x, event.y, event.z, DateTime.now()));
    });
  }

  void _checkBuffer() {
    if (buffer.isWindowFull()) {
      // Pass a copy or just trigger callback, then clear
      onWindowFull(buffer);
      buffer.clear();
    }
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _accelSub?.cancel();
    _gyroSub?.cancel();
    buffer.clear();
  }
}
