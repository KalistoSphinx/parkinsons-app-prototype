import 'package:flutter_test/flutter_test.dart';
import 'package:prototype/models/session_feature_vector.dart';

void main() {
  test('session vector keeps metadata outside fixed numerical feature columns', () {
    final vector = SessionFeatureVector(
      patientId: 'patient-1',
      sessionId: 'session-1',
      timestamp: DateTime.utc(2026, 10, 7),
      taskType: 'tremor',
      qualityPassed: true,
      features: const {
        'tremor_probability': 0.8,
        'tremor_power': 1.2,
      },
    );

    final document = vector.toMap();

    expect(featureColumns, hasLength(8));
    expect(featureColumnsByTask['tremor'], contains('tremor_probability'));
    expect(featureColumnsByTask['gait'], contains('arm_swing_rom'));
    expect(document['sessionId'], 'session-1');
    expect(document['patientId'], 'patient-1');
    expect(featureColumns.map((name) => document[name]).first, 0.8);
    expect(document.keys, containsAll(featureColumns));
    expect(document['gait_probability'], isNull);

    final restored = SessionFeatureVector.fromMap(document);
    expect(restored.features['tremor_power'], 1.2);
    expect(restored.features['gait_probability'], isNull);
    expect(restored.baselineStatus, 'included');
  });

  test('server monitoring documents sync into the local Hive feature schema', () {
    final vector = SessionFeatureVector.fromMap({
      'patient_id': 'patient-2',
      'session_id': 'interval-1',
      'timestamp': '2026-10-07T12:00:00+00:00',
      'task_type': 'monitoring',
      'quality_passed': true,
      'baseline_status': 'included',
      'symptom_labels': {'tremor': 'normal'},
      'features': {'tremor_probability': 0.2, 'gyro_rms_rad_s': 0.5},
    });

    expect(vector.patientId, 'patient-2');
    expect(vector.features['gyro_rms_rad_s'], 0.5);
    expect(vector.symptomLabels['tremor'], 'normal');
    expect(vector.qualityPassed, isTrue);
  });
}
