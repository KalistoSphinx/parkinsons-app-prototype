import 'package:flutter_test/flutter_test.dart';
import 'package:prototype/models/health_alert.dart';
import 'package:prototype/models/session_feature_vector.dart';

void main() {
  group('HealthAlert', () {
    final payload = <String, dynamic>{
      'alert_id': 'alert-1',
      'patient_id': 'patient-1',
      'session_id': 'session-1',
      'symptom': 'tremor',
      'severity': 'warning',
      'status': 'new',
      'title': 'Tremor above personal baseline',
      'message': 'Rest tremor was higher than usual.',
      'model': 'robust_z',
      'context': 'rest',
      'created_at': '2026-10-22T10:00:00+00:00',
      'timestamp_ms': 1792663200000,
      'score': 0.82,
      'drivers': [
        {
          'feature': 'tremor_probability',
          'direction': 'high',
          'symptom': 'tremor',
          'z': 3.1,
          'value': 0.4,
          'baseline_median': 0.02,
        },
      ],
      'evidence_session_ids': ['session-0', 'session-1'],
    };

    test('parses backend alert JSON', () {
      final alert = HealthAlert.fromMap(payload);

      expect(alert.alertId, 'alert-1');
      expect(alert.patientId, 'patient-1');
      expect(alert.severity, 'warning');
      expect(alert.isOpen, isTrue);
      expect(alert.drivers, hasLength(1));
      expect(alert.drivers.first.feature, 'tremor_probability');
      expect(alert.drivers.first.z, 3.1);
      expect(alert.evidenceSessionIds, ['session-0', 'session-1']);
    });

    test('round-trips through toMap', () {
      final restored = HealthAlert.fromMap(HealthAlert.fromMap(payload).toMap());

      expect(restored.alertId, 'alert-1');
      expect(restored.title, 'Tremor above personal baseline');
      expect(restored.score, closeTo(0.82, 0.0001));
      expect(restored.createdAt.toUtc().toIso8601String(), '2026-10-22T10:00:00.000Z');
    });

    test('acknowledgment keeps the alert open for rule tracking', () {
      final acknowledged = HealthAlert.fromMap(payload).copyWith(status: 'acknowledged');

      expect(acknowledged.status, 'acknowledged');
      expect(acknowledged.isOpen, isTrue);
    });
  });

  group('SessionFeatureVector', () {
    test('preserves monitoring mode, anomaly, and alert ids', () {
      final vector = SessionFeatureVector.fromMap({
        'patient_id': 'patient-1',
        'session_id': 'session-1',
        'timestamp': '2026-10-22T10:00:00+00:00',
        'task_type': 'monitoring',
        'monitoring_mode': 'anomaly',
        'quality_passed': true,
        'baseline_status': 'excluded',
        'symptom_labels': {'tremor': 'moderate'},
        'tremor_probability': 0.4,
        'gait_probability': 0.1,
        'anomaly': {
          'severity': 'warning',
          'drivers': [],
          'symptoms': {'tremor': 'warning'},
        },
        'alert_ids': ['alert-1'],
      });

      expect(vector.monitoringMode, 'anomaly');
      expect(vector.baselineStatus, 'excluded');
      expect(vector.anomaly?['severity'], 'warning');
      expect(vector.alertIds, ['alert-1']);

      final map = vector.toMap();
      expect(map['monitoringMode'], 'anomaly');
      expect(map['alertIds'], ['alert-1']);
      expect(map['anomaly'], isA<Map<String, dynamic>>());
    });

    test('defaults older documents to baseline mode', () {
      final vector = SessionFeatureVector.fromMap({
        'patient_id': 'patient-1',
        'session_id': 'session-1',
        'timestamp': '2026-10-22T10:00:00+00:00',
        'task_type': 'monitoring',
        'quality_passed': true,
        'tremor_probability': 0.1,
      });

      expect(vector.monitoringMode, 'baseline');
      expect(vector.baselineStatus, 'included');
      expect(vector.alertIds, isEmpty);
      expect(vector.anomaly, isNull);
    });
  });
}
