import 'dart:math';
import 'package:collection/collection.dart';
import '../models/feature_measurement.dart';
import '../models/baseline.dart';
import '../database/local_database.dart';

class BaselineManager {
  final LocalDatabase _db;

  BaselineManager(this._db);

  Future<void> recalculateBaseline(String patientId, String featureName, {int minSamples = 5}) async {
    List<FeatureMeasurement> measurements = await _db.getMeasurements(
      patientId, 
      featureName: featureName,
    );

    if (measurements.length < minSamples) {
      return; // Not enough data
    }

    List<double> values = measurements.map((m) => m.value).toList();
    values.sort();

    double mean = values.average;
    
    double sumSq = values.fold(0.0, (sum, val) => sum + pow(val - mean, 2));
    double std = sqrt(sumSq / (values.length - 1));
    
    double min = values.first;
    double max = values.last;
    
    double getPercentile(double p) {
      int index = (p * (values.length - 1)).round();
      return values[index];
    }

    Baseline baseline = Baseline(
      id: '${patientId}_$featureName',
      patientId: patientId,
      featureName: featureName,
      mean: mean,
      median: getPercentile(0.50),
      std: std,
      min: min,
      max: max,
      p05: getPercentile(0.05),
      p25: getPercentile(0.25),
      p75: getPercentile(0.75),
      p95: getPercentile(0.95),
      sampleCount: values.length,
      lastUpdated: DateTime.now(),
    );

    await _db.saveBaseline(baseline);
  }

  Future<double?> getFeatureDeviation(String patientId, String featureName, double currentValue) async {
    Baseline? baseline = await _db.getBaseline(patientId, featureName);
    if (baseline == null) return null;
    if (baseline.std == 0) return 0.0; // Avoid division by zero

    // Z-Score
    return (currentValue - baseline.mean) / baseline.std;
  }
}
