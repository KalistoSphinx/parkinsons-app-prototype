import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:prototype/sensors/window_buffer.dart';
import 'package:prototype/sensors/sensor_service.dart';
import 'package:prototype/feature_extraction/tremor_analyzer.dart';
import 'package:prototype/signal_processing/dsp_utils.dart';

void main() {
  group('DSP Utils Tests', () {
    test('Mean calculation', () {
      expect(DspUtils.mean([1, 2, 3, 4, 5]), 3.0);
    });

    test('RMS calculation', () {
      expect(DspUtils.rms([2, -2, 2, -2]), 2.0);
    });

    test('Frequency extraction', () {
      // Create a 5 Hz sine wave sampled at 50 Hz
      double samplingRate = 50.0;
      double freq = 5.0;
      List<double> signal = [];
      for (int i = 0; i < 256; i++) { // Power of 2 is good for FFT
        double t = i / samplingRate;
        signal.add(sin(2 * pi * freq * t));
      }

      var features = DspUtils.extractFrequencyFeatures(signal, samplingRate, 4.0, 6.0);
      
      // Dominant frequency should be close to 5.0 Hz
      expect(features['dominantFrequency']!, closeTo(5.0, 0.5));
    });
  });

  group('Tremor Analyzer Tests', () {
    test('Extracts features correctly from synthetic buffer', () {
      final buffer = WindowBuffer(windowDurationMs: 5000);
      
      double samplingRate = 50.0;
      double freq = 5.0; // Simulated tremor at 5Hz
      
      // Generate 5 seconds of data = 250 samples
      DateTime startTime = DateTime.now();
      for (int i = 0; i < 250; i++) {
        double t = i / samplingRate;
        double val = sin(2 * pi * freq * t) * 0.5; // Amplitude 0.5
        
        DateTime ts = startTime.add(Duration(milliseconds: (t * 1000).toInt()));
        
        // Add sample (only accel is used by TremorAnalyzer)
        buffer.addAccelSample(SensorSample(val, 0, 0, ts)); // only X axis movement
      }

      final analyzer = TremorAnalyzer();
      final features = analyzer.extractFeatures(buffer);

      expect(features['dominantFrequency'], isNotNull);
      expect(features['dominantFrequency'], closeTo(5.0, 0.5));
      expect(features['tremorAmplitude'], greaterThan(0));
    });
  });
}
