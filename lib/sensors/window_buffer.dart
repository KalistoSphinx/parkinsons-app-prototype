class SensorSample {
  final double x;
  final double y;
  final double z;
  final DateTime timestamp;

  SensorSample(this.x, this.y, this.z, this.timestamp);
}

class WindowBuffer {
  final List<SensorSample> accelBuffer = [];
  final List<SensorSample> gyroBuffer = [];
  final int windowDurationMs;
  
  WindowBuffer({required this.windowDurationMs});
  
  void addAccelSample(SensorSample sample) {
    accelBuffer.add(sample);
  }
  
  void addGyroSample(SensorSample sample) {
    gyroBuffer.add(sample);
  }
  
  bool isWindowFull() {
    if (accelBuffer.isEmpty) return false;
    final firstTime = accelBuffer.first.timestamp;
    final lastTime = accelBuffer.last.timestamp;
    return lastTime.difference(firstTime).inMilliseconds >= windowDurationMs;
  }
  
  void clear() {
    accelBuffer.clear();
    gyroBuffer.clear();
  }
  
  List<SensorSample> getAccelData() => List.unmodifiable(accelBuffer);
  List<SensorSample> getGyroData() => List.unmodifiable(gyroBuffer);
  
  double calculateSamplingRate(List<SensorSample> buffer) {
    if (buffer.length < 2) return 0.0;
    final duration = buffer.last.timestamp.difference(buffer.first.timestamp).inMilliseconds;
    if (duration == 0) return 0.0;
    return buffer.length / (duration / 1000.0);
  }
}
