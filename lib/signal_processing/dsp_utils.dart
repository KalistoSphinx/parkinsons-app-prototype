import 'dart:math';
import 'package:fftea/fftea.dart';

class DspUtils {
  static double mean(List<double> data) {
    if (data.isEmpty) return 0;
    return data.reduce((a, b) => a + b) / data.length;
  }

  static double variance(List<double> data, {double? precalculatedMean}) {
    if (data.length < 2) return 0;
    final m = precalculatedMean ?? mean(data);
    double sum = 0;
    for (var val in data) {
      sum += pow(val - m, 2);
    }
    return sum / (data.length - 1);
  }

  static double stdDev(List<double> data, {double? precalculatedMean}) {
    return sqrt(variance(data, precalculatedMean: precalculatedMean));
  }

  static double rms(List<double> data) {
    if (data.isEmpty) return 0;
    double sumSq = data.fold(0, (sum, val) => sum + (val * val));
    return sqrt(sumSq / data.length);
  }

  static double peakToPeak(List<double> data) {
    if (data.isEmpty) return 0;
    double minVal = data.first;
    double maxVal = data.first;
    for (var val in data) {
      if (val < minVal) minVal = val;
      if (val > maxVal) maxVal = val;
    }
    return maxVal - minVal;
  }

  static double energy(List<double> data) {
    return data.fold(0, (sum, val) => sum + (val * val));
  }

  /// Removes DC offset (gravity/mean) from the signal
  static List<double> removeDcOffset(List<double> data) {
    final m = mean(data);
    return data.map((e) => e - m).toList();
  }

  /// Calculate signal vector magnitude (SVM) for 3D data
  static List<double> calculateSvm(List<double> x, List<double> y, List<double> z) {
    List<double> svm = [];
    int length = [x.length, y.length, z.length].reduce(min);
    for (int i = 0; i < length; i++) {
      svm.add(sqrt(x[i]*x[i] + y[i]*y[i] + z[i]*z[i]));
    }
    return svm;
  }
  
  /// Applies a simple moving average filter
  static List<double> movingAverage(List<double> data, int windowSize) {
    if (data.isEmpty || windowSize <= 1) return List.from(data);
    List<double> result = [];
    double sum = 0;
    for (int i = 0; i < data.length; i++) {
      sum += data[i];
      if (i >= windowSize) {
        sum -= data[i - windowSize];
        result.add(sum / windowSize);
      } else {
        result.add(sum / (i + 1));
      }
    }
    return result;
  }

  /// Calculates frequency domain features using FFT.
  /// Returns a map of features: dominant frequency, total power, band power.
  static Map<String, double> extractFrequencyFeatures(
    List<double> data, 
    double samplingRate,
    double bandMinFreq,
    double bandMaxFreq,
  ) {
    if (data.length < 4) {
      return {
        'dominantFrequency': 0.0,
        'totalPower': 0.0,
        'bandPower': 0.0,
      };
    }
    
    // Ensure power of 2 for optimal FFT
    int n = 1;
    while (n * 2 <= data.length) {n *= 2;}
    List<double> paddedData = data.sublist(0, n);

    final fft = FFT(paddedData.length);
    final freqData = fft.realFft(paddedData);
    
    // Calculate Power Spectral Density (PSD)
    List<double> psd = [];
    double maxPower = 0.0;
    int dominantIdx = 0;
    
    // fft.realFft returns complex numbers. Power is mag squared.
    // The size of freqData is (N/2) + 1 elements.
    for (int i = 0; i < freqData.length; i++) {
      double real = freqData[i].x;
      double imag = freqData[i].y;
      double power = (real * real + imag * imag) / paddedData.length;
      psd.add(power);
      
      if (i > 0 && power > maxPower) { // Skip DC component (i=0) for dominant frequency
        maxPower = power;
        dominantIdx = i;
      }
    }

    double freqRes = samplingRate / paddedData.length;
    double dominantFrequency = dominantIdx * freqRes;
    
    double totalPower = 0.0;
    double bandPower = 0.0;
    
    for (int i = 1; i < psd.length; i++) { // Skip DC component
      totalPower += psd[i];
      double freq = i * freqRes;
      if (freq >= bandMinFreq && freq <= bandMaxFreq) {
        bandPower += psd[i];
      }
    }

    return {
      'dominantFrequency': dominantFrequency,
      'totalPower': totalPower,
      'bandPower': bandPower,
    };
  }
}
