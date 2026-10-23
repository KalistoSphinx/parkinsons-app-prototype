/// Numerical feature columns shared with the Python processing service.
/// Metadata fields are deliberately excluded for future model training.
const List<String> featureColumns = [
  'tremor_probability',
  'tremor_power',
  'tremor_time',
  'gait_probability',
  'arm_swing_rom',
  'arm_swing_peak_velocity',
  'accel_rms_m_s2',
  'gyro_rms_rad_s',
  'fall_detected',
  'fall_impact_g',
];

/// ParaDigMa task outputs differ by task, so future anomaly models should be
/// trained/inferred on one task's ordered, actually-applicable columns.
const Map<String, List<String>> featureColumnsByTask = {
  'tremor': [
    'tremor_probability',
    'tremor_power',
    'tremor_time',
    'gyro_rms_rad_s',
  ],
  'gait': [
    'gait_probability',
    'arm_swing_rom',
    'arm_swing_peak_velocity',
    'accel_rms_m_s2',
    'gyro_rms_rad_s',
  ],
  'monitoring': featureColumns,
};

class SessionFeatureVector {
  final String patientId;
  final String sessionId;
  final DateTime timestamp;
  final String taskType;
  final String monitoringMode;
  final Map<String, double?> features;
  final bool qualityPassed;
  final String baselineStatus;
  final String processingMessage;
  final String sourceLabel;
  final Map<String, String> symptomLabels;
  final Map<String, dynamic>? anomaly;
  final List<String> alertIds;

  const SessionFeatureVector({
    required this.patientId,
    required this.sessionId,
    required this.timestamp,
    required this.taskType,
    required this.features,
    required this.qualityPassed,
    this.monitoringMode = 'baseline',
    this.baselineStatus = 'included',
    this.processingMessage = '',
    this.sourceLabel = 'device-session',
    this.symptomLabels = const {},
    this.anomaly,
    this.alertIds = const [],
  });

  Map<String, dynamic> toMap() => {
    'patientId': patientId,
    'sessionId': sessionId,
    'timestamp': timestamp.toIso8601String(),
    'taskType': taskType,
    'monitoringMode': monitoringMode,
    'qualityPassed': qualityPassed,
    'baselineStatus': baselineStatus,
    'processingMessage': processingMessage,
    'sourceLabel': sourceLabel,
    'symptomLabels': symptomLabels,
    'anomaly': anomaly,
    'alertIds': alertIds,
    ...{for (final name in featureColumns) name: features[name]},
  };

  factory SessionFeatureVector.fromMap(Map<String, dynamic> map) {
    final rawFeatures = map['features'] as Map<String, dynamic>? ?? map;
    final patientId = (map['patientId'] ?? map['patient_id']) as String;
    final sessionId = (map['sessionId'] ?? map['session_id']) as String;
    final taskType = (map['taskType'] ?? map['task_type']) as String;
    final qualityPassed = (map['qualityPassed'] ?? map['quality_passed']) as bool? ?? false;
    final rawLabels = map['symptomLabels'] ?? map['symptom_labels'];
    final labels = rawLabels is Map ? rawLabels : const <String, dynamic>{};
    final rawTimestamp = map['timestamp'];
    final timestamp = rawTimestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt(), isUtc: true)
        : DateTime.parse(rawTimestamp as String);

    return SessionFeatureVector(
      patientId: patientId,
      sessionId: sessionId,
      timestamp: timestamp,
      taskType: taskType,
      monitoringMode: (map['monitoringMode'] ?? map['monitoring_mode']) as String? ??
          'baseline',
      qualityPassed: qualityPassed,
      baselineStatus: (map['baselineStatus'] ?? map['baseline_status']) as String? ??
          (qualityPassed ? 'included' : 'excluded'),
      processingMessage: (map['processingMessage'] ?? map['quality_message']) as String? ?? '',
      sourceLabel: map['sourceLabel'] as String? ?? 'continuous-device-monitoring',
      symptomLabels: labels.map((key, value) => MapEntry(key.toString(), value.toString())),
      anomaly: (map['anomaly'] as Map?)?.cast<String, dynamic>(),
      alertIds: (map['alertIds'] ?? map['alert_ids']) is List
          ? ((map['alertIds'] ?? map['alert_ids']) as List)
              .map((value) => value.toString())
              .toList()
          : const [],
      features: {
        for (final name in featureColumns)
          name: rawFeatures[name] == null ? null : (rawFeatures[name] as num).toDouble(),
      },
    );
  }

  SessionFeatureVector copyWith({String? baselineStatus}) =>
      SessionFeatureVector(
        patientId: patientId,
        sessionId: sessionId,
        timestamp: timestamp,
        taskType: taskType,
        monitoringMode: monitoringMode,
        features: features,
        qualityPassed: qualityPassed,
        baselineStatus: baselineStatus ?? this.baselineStatus,
        processingMessage: processingMessage,
        sourceLabel: sourceLabel,
        symptomLabels: symptomLabels,
        anomaly: anomaly,
        alertIds: alertIds,
      );
}
