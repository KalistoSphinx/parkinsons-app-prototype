class Baseline {
  final String id;
  final String patientId;
  final String featureName;
  final double mean;
  final double median;
  final double std;
  final double min;
  final double max;
  final double p05;
  final double p25;
  final double p75;
  final double p95;
  final int sampleCount;
  final DateTime lastUpdated;

  Baseline({
    required this.id,
    required this.patientId,
    required this.featureName,
    required this.mean,
    required this.median,
    required this.std,
    required this.min,
    required this.max,
    required this.p05,
    required this.p25,
    required this.p75,
    required this.p95,
    required this.sampleCount,
    required this.lastUpdated,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientId': patientId,
      'featureName': featureName,
      'mean': mean,
      'median': median,
      'std': std,
      'min': min,
      'max': max,
      'p05': p05,
      'p25': p25,
      'p75': p75,
      'p95': p95,
      'sampleCount': sampleCount,
      'lastUpdated': lastUpdated.toIso8601String(),
    };
  }

  factory Baseline.fromMap(Map<String, dynamic> map) {
    return Baseline(
      id: map['id'],
      patientId: map['patientId'],
      featureName: map['featureName'],
      mean: (map['mean'] as num).toDouble(),
      median: (map['median'] as num).toDouble(),
      std: (map['std'] as num).toDouble(),
      min: (map['min'] as num).toDouble(),
      max: (map['max'] as num).toDouble(),
      p05: (map['p05'] as num).toDouble(),
      p25: (map['p25'] as num).toDouble(),
      p75: (map['p75'] as num).toDouble(),
      p95: (map['p95'] as num).toDouble(),
      sampleCount: map['sampleCount'] as int,
      lastUpdated: DateTime.parse(map['lastUpdated']),
    );
  }
}
