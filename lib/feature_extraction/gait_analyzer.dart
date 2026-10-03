import '../sensors/window_buffer.dart';
import '../signal_processing/dsp_utils.dart';

class GaitAnalyzer {
  
  Map<String, double> extractFeatures(WindowBuffer buffer) {
    final accel = buffer.getAccelData();
    if (accel.isEmpty) return {};

    double samplingRate = buffer.calculateSamplingRate(accel);
    
    List<double> x = accel.map((s) => s.x).toList();
    List<double> y = accel.map((s) => s.y).toList();
    List<double> z = accel.map((s) => s.z).toList();
    
    // Use SVM to be independent of phone orientation in pocket/hand
    List<double> svm = DspUtils.calculateSvm(x, y, z);
    
    // Remove gravity
    svm = DspUtils.removeDcOffset(svm);
    
    // Low-pass filter to isolate steps (walking frequency is typically 1.5 - 2.5 Hz)
    // Moving average is a simple approximation
    int windowSize = (samplingRate * 0.2).ceil().clamp(2, 20); // ~200ms window
    List<double> smoothed = DspUtils.movingAverage(svm, windowSize);
    
    double meanVal = DspUtils.mean(smoothed);
    double stdDev = DspUtils.stdDev(smoothed, precalculatedMean: meanVal);
    
    // Simple peak detection for step counting
    // A step creates a peak in acceleration SVM
    double threshold = meanVal + (stdDev * 0.5); 
    int stepCount = 0;
    List<int> peakIndices = [];
    
    bool isPeak = false;
    for (int i = 1; i < smoothed.length - 1; i++) {
      if (smoothed[i] > threshold && smoothed[i] > smoothed[i-1] && smoothed[i] > smoothed[i+1]) {
        if (!isPeak) {
          stepCount++;
          peakIndices.add(i);
          isPeak = true;
        }
      } else if (smoothed[i] < meanVal) {
        isPeak = false;
      }
    }

    double durationSeconds = buffer.windowDurationMs / 1000.0;
    double cadence = durationSeconds > 0 ? (stepCount / durationSeconds) * 60 : 0; // steps per minute
    
    // Step intervals
    List<double> stepIntervalsMs = [];
    for (int i = 1; i < peakIndices.length; i++) {
      double interval = (peakIndices[i] - peakIndices[i-1]) / samplingRate * 1000;
      stepIntervalsMs.add(interval);
    }
    
    double avgStepInterval = DspUtils.mean(stepIntervalsMs);
    double stepIntervalVariability = DspUtils.stdDev(stepIntervalsMs, precalculatedMean: avgStepInterval);

    return {
      'stepCount': stepCount.toDouble(),
      'cadence': cadence, // Steps per minute
      'accelRms': DspUtils.rms(svm),
      'avgStepIntervalMs': avgStepInterval,
      'stepIntervalVariability': stepIntervalVariability,
    };
  }
}
