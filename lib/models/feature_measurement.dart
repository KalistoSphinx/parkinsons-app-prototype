class FeatureMeasurement {
  final String id;
  final String sessionId;
  final String patientId;
  final DateTime timestamp;
  final String featureName;
  final double value;

  FeatureMeasurement({
    required this.id,
    required this.sessionId,
    required this.patientId,
    required this.timestamp,
    required this.featureName,
    required this.value,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sessionId': sessionId,
      'patientId': patientId,
      'timestamp': timestamp.toIso8601String(),
      'featureName': featureName,
      'value': value,
    };
  }

  factory FeatureMeasurement.fromMap(Map<String, dynamic> map) {
    return FeatureMeasurement(
      id: map['id'],
      sessionId: map['sessionId'],
      patientId: map['patientId'],
      timestamp: DateTime.parse(map['timestamp']),
      featureName: map['featureName'],
      value: map['value'] is int ? (map['value'] as int).toDouble() : map['value'],
    );
  }
}
