class AlertDriver {
  final String feature;
  final String direction;
  final String symptom;
  final double z;
  final double value;
  final double baselineMedian;

  const AlertDriver({
    required this.feature,
    required this.direction,
    required this.symptom,
    required this.z,
    required this.value,
    required this.baselineMedian,
  });

  factory AlertDriver.fromMap(Map<String, dynamic> map) {
    return AlertDriver(
      feature: map['feature']?.toString() ?? '',
      direction: map['direction']?.toString() ?? '',
      symptom: map['symptom']?.toString() ?? '',
      z: (map['z'] as num?)?.toDouble() ?? 0,
      value: (map['value'] as num?)?.toDouble() ?? 0,
      baselineMedian: (map['baseline_median'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'feature': feature,
        'direction': direction,
        'symptom': symptom,
        'z': z,
        'value': value,
        'baseline_median': baselineMedian,
      };
}

class HealthAlert {
  final String alertId;
  final String patientId;
  final String sessionId;
  final String symptom;
  final String severity;
  final String status;
  final String title;
  final String message;
  final String model;
  final String context;
  final DateTime createdAt;
  final int timestampMs;
  final double score;
  final List<AlertDriver> drivers;
  final List<String> evidenceSessionIds;

  const HealthAlert({
    required this.alertId,
    required this.patientId,
    required this.sessionId,
    required this.symptom,
    required this.severity,
    required this.status,
    required this.title,
    required this.message,
    required this.model,
    required this.context,
    required this.createdAt,
    required this.timestampMs,
    required this.score,
    this.drivers = const [],
    this.evidenceSessionIds = const [],
  });

  bool get isOpen => status != 'resolved';

  String get formattedTime {
    final local = createdAt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  factory HealthAlert.fromMap(Map<String, dynamic> map) {
    final rawCreated = map['created_at'] ?? map['createdAt'];
    final createdAt = rawCreated is num
        ? DateTime.fromMillisecondsSinceEpoch(rawCreated.toInt(), isUtc: true)
        : DateTime.tryParse(rawCreated?.toString() ?? '') ?? DateTime.now();
    final rawDrivers = map['drivers'];
    final rawEvidence = map['evidence_session_ids'] ?? map['evidenceSessionIds'];

    return HealthAlert(
      alertId: map['alert_id']?.toString() ?? map['alertId']?.toString() ?? '',
      patientId: map['patient_id']?.toString() ?? map['patientId']?.toString() ?? '',
      sessionId: map['session_id']?.toString() ?? map['sessionId']?.toString() ?? '',
      symptom: map['symptom']?.toString() ?? '',
      severity: map['severity']?.toString() ?? 'warning',
      status: map['status']?.toString() ?? 'new',
      title: map['title']?.toString() ?? 'Movement change detected',
      message: map['message']?.toString() ?? '',
      model: map['model']?.toString() ?? 'robust_z',
      context: map['context']?.toString() ?? 'unknown',
      createdAt: createdAt,
      timestampMs: (map['timestamp_ms'] as num?)?.toInt() ??
          createdAt.millisecondsSinceEpoch,
      score: (map['score'] as num?)?.toDouble() ?? 0,
      drivers: rawDrivers is List
          ? rawDrivers
              .whereType<Map>()
              .map((item) => AlertDriver.fromMap(
                    item.map((key, value) => MapEntry(key.toString(), value)),
                  ))
              .toList()
          : const [],
      evidenceSessionIds: rawEvidence is List
          ? rawEvidence.map((value) => value.toString()).toList()
          : const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'alert_id': alertId,
        'patient_id': patientId,
        'session_id': sessionId,
        'symptom': symptom,
        'severity': severity,
        'status': status,
        'title': title,
        'message': message,
        'model': model,
        'context': context,
        'created_at': createdAt.toIso8601String(),
        'timestamp_ms': timestampMs,
        'score': score,
        'drivers': drivers.map((driver) => driver.toMap()).toList(),
        'evidence_session_ids': evidenceSessionIds,
      };

  HealthAlert copyWith({String? status}) => HealthAlert(
        alertId: alertId,
        patientId: patientId,
        sessionId: sessionId,
        symptom: symptom,
        severity: severity,
        status: status ?? this.status,
        title: title,
        message: message,
        model: model,
        context: context,
        createdAt: createdAt,
        timestampMs: timestampMs,
        score: score,
        drivers: drivers,
        evidenceSessionIds: evidenceSessionIds,
      );
}
