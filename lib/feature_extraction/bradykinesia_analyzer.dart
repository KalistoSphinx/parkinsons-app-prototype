import '../sensors/window_buffer.dart';
import '../signal_processing/dsp_utils.dart';

class BradykinesiaAnalyzer {
  
  Map<String, double> extractFeatures(WindowBuffer buffer) {
    final gyro = buffer.getGyroData();
    if (gyro.isEmpty) return {};

    double samplingRate = buffer.calculateSamplingRate(gyro);
    
    // For bradykinesia (slowness of movement), we look at rotational velocity (gyroscope).
    List<double> x = gyro.map((s) => s.x).toList();
    List<double> y = gyro.map((s) => s.y).toList();
    List<double> z = gyro.map((s) => s.z).toList();
    
    List<double> svm = DspUtils.calculateSvm(x, y, z);
    
    // Apply low-pass filter (moving average) to smooth out high frequency noise/tremor
    List<double> smoothedSvm = DspUtils.movingAverage(svm, (samplingRate * 0.1).ceil().clamp(2, 10));
    
    double meanVal = DspUtils.mean(smoothedSvm);
    double stdDev = DspUtils.stdDev(smoothedSvm, precalculatedMean: meanVal);
    double rms = DspUtils.rms(smoothedSvm);
    
    // Detect movements (peaks)
    // A simple threshold-based movement detection
    double threshold = meanVal + stdDev; 
    int movementCount = 0;
    bool inMovement = false;
    List<double> movementAmplitudes = [];
    
    double currentMax = 0;

    for (int i = 0; i < smoothedSvm.length; i++) {
      if (smoothedSvm[i] > threshold) {
        if (!inMovement) {
          inMovement = true;
          movementCount++;
          currentMax = smoothedSvm[i];
        } else {
          if (smoothedSvm[i] > currentMax) {
            currentMax = smoothedSvm[i];
          }
        }
      } else {
        if (inMovement) {
          inMovement = false;
          movementAmplitudes.add(currentMax);
        }
      }
    }

    double movementFrequency = buffer.windowDurationMs > 0 
        ? (movementCount / (buffer.windowDurationMs / 1000.0)) 
        : 0;

    double avgAmplitude = DspUtils.mean(movementAmplitudes);
    double ampStd = DspUtils.stdDev(movementAmplitudes, precalculatedMean: avgAmplitude);
    
    // Amplitude reduction (fatigue / decrement)
    // Compare first half of movements to second half
    double amplitudeReduction = 0;
    if (movementAmplitudes.length >= 4) {
      int half = movementAmplitudes.length ~/ 2;
      double firstHalfAvg = DspUtils.mean(movementAmplitudes.sublist(0, half));
      double secondHalfAvg = DspUtils.mean(movementAmplitudes.sublist(half));
      if (firstHalfAvg > 0) {
        amplitudeReduction = (firstHalfAvg - secondHalfAvg) / firstHalfAvg;
      }
    }

    return {
      'gyroRms': rms,
      'movementCount': movementCount.toDouble(),
      'movementFrequency': movementFrequency,
      'avgMovementAmplitude': avgAmplitude,
      'movementAmplitudeVariability': ampStd,
      'amplitudeReduction': amplitudeReduction,
    };
  }
}
