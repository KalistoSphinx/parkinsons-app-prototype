import '../sensors/window_buffer.dart';
import '../signal_processing/dsp_utils.dart';

class TremorAnalyzer {
  final double bandMinFreq;
  final double bandMaxFreq;

  TremorAnalyzer({
    this.bandMinFreq = 4.0, // Typical Parkinson's rest tremor is 4-6 Hz
    this.bandMaxFreq = 6.0,
  });

  Map<String, double> extractFeatures(WindowBuffer buffer) {
    final accel = buffer.getAccelData();
    if (accel.isEmpty) return {};

    double samplingRate = buffer.calculateSamplingRate(accel);
    
    List<double> x = accel.map((s) => s.x).toList();
    List<double> y = accel.map((s) => s.y).toList();
    List<double> z = accel.map((s) => s.z).toList();

    // 1. Preprocessing: Remove DC offset (gravity)
    x = DspUtils.removeDcOffset(x);
    y = DspUtils.removeDcOffset(y);
    z = DspUtils.removeDcOffset(z);

    // 2. Calculate Signal Vector Magnitude (SVM) for orientation-independent analysis
    List<double> svm = DspUtils.calculateSvm(x, y, z);
    svm = DspUtils.removeDcOffset(svm); // Remove mean of SVM

    // 3. Time Domain Features
    double meanVal = DspUtils.mean(svm);
    double stdDev = DspUtils.stdDev(svm, precalculatedMean: meanVal);
    double variance = DspUtils.variance(svm, precalculatedMean: meanVal);
    double rms = DspUtils.rms(svm);
    double peakToPeak = DspUtils.peakToPeak(svm);
    double energy = DspUtils.energy(svm);

    // 4. Frequency Domain Features
    // Find axis with highest variance to analyze frequency
    double varX = DspUtils.variance(x);
    double varY = DspUtils.variance(y);
    double varZ = DspUtils.variance(z);
    
    List<double> dominantAxisData = x;
    if (varY > varX && varY > varZ) dominantAxisData = y;
    if (varZ > varX && varZ > varY) dominantAxisData = z;

    Map<String, double> freqFeatures = DspUtils.extractFrequencyFeatures(
      dominantAxisData, 
      samplingRate, 
      bandMinFreq, 
      bandMaxFreq,
    );

    double totalPower = freqFeatures['totalPower']!;
    double bandPower = freqFeatures['bandPower']!;
    double ratio = totalPower > 0 ? bandPower / totalPower : 0;

    return {
      'samplingRate': samplingRate,
      'tremorAmplitude': peakToPeak,
      'rms': rms,
      'variance': variance,
      'energy': energy,
      'dominantFrequency': freqFeatures['dominantFrequency']!,
      'totalPower': totalPower,
      'tremorBandPower': bandPower,
      'tremorBandRatio': ratio,
    };
  }
}
