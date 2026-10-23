import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/health_alert.dart';
import '../models/patient.dart';
import '../models/session_feature_vector.dart';

/// Hive CE NoSQL profile store. Processed time-series feature documents live on
/// the Python service so they remain available while the Android app is closed.
class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._();
  LocalDatabase._();

  Future<void>? _initializing;
  late Box<String> _patients;
  late Box<String> _features;
  late Box<String> _alerts;
  late Box<String> _syncState;

  Future<void> initialize() => _initializing ??= _open();

  Future<void> _open() async {
    final directory = await getApplicationSupportDirectory();
    Hive.init(directory.path);
    _patients = await Hive.openBox<String>('patients');
    _features = await Hive.openBox<String>('session_features');
    _alerts = await Hive.openBox<String>('health_alerts');
    _syncState = await Hive.openBox<String>('sync_state');
  }

  Future<void> _ready() => initialize();

  Future<void> createPatient(Patient patient) async {
    await _ready();
    await _patients.put(patient.id, jsonEncode(patient.toMap()));
  }

  Future<List<Patient>> getPatients() async {
    await _ready();
    return _patients.values
        .map((value) => Patient.fromMap(jsonDecode(value) as Map<String, dynamic>))
        .toList();
  }

  Future<void> deletePatient(String patientId) async {
    await _ready();
    await _patients.delete(patientId);
    final keysToRemove = _features.keys
        .where((key) {
          final val = _features.get(key);
          if (val == null) return false;
          try {
            final map = jsonDecode(val) as Map<String, dynamic>;
            return map['patientId'] == patientId;
          } catch (_) {
            return false;
          }
        })
        .toList();
    for (final key in keysToRemove) {
      await _features.delete(key);
    }
    final alertKeysToRemove = _alerts.keys
        .where((key) {
          final val = _alerts.get(key);
          if (val == null) return false;
          try {
            final map = jsonDecode(val) as Map<String, dynamic>;
            return map['patient_id'] == patientId;
          } catch (_) {
            return false;
          }
        })
        .toList();
    for (final key in alertKeysToRemove) {
      await _alerts.delete(key);
    }
    await _syncState.delete('feature-cursor:$patientId');
  }

  Future<void> saveAlert(HealthAlert alert) async {
    await _ready();
    await _alerts.put(alert.alertId, jsonEncode(alert.toMap()));
  }

  Future<List<HealthAlert>> getAlerts(String patientId) async {
    await _ready();
    final alerts = <HealthAlert>[];
    for (final value in _alerts.values) {
      try {
        final alert =
            HealthAlert.fromMap(jsonDecode(value) as Map<String, dynamic>);
        if (alert.patientId == patientId) alerts.add(alert);
      } catch (_) {
        // Ignore a malformed local alert rather than breaking the dashboard.
      }
    }
    alerts.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return alerts;
  }

  Future<void> acknowledgeAlert(String patientId, String alertId) async {
    await _ready();
    final raw = _alerts.get(alertId);
    if (raw == null) return;
    final alert = HealthAlert.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    await _alerts.put(alertId, jsonEncode(alert.copyWith(status: 'acknowledged').toMap()));
  }

  Future<void> saveFeatureVector(SessionFeatureVector vector) async {
    await _ready();
    await _features.put(vector.sessionId, jsonEncode(vector.toMap()));
    final key = 'feature-cursor:${vector.patientId}';
    final cursor = int.tryParse(_syncState.get(key) ?? '') ?? 0;
    final timestamp = vector.timestamp.millisecondsSinceEpoch;
    if (timestamp > cursor) await _syncState.put(key, '$timestamp');
  }

  Future<List<SessionFeatureVector>> getFeatureVectors(String patientId) async {
    await _ready();
    final vectors = _features.values
        .map((value) => SessionFeatureVector.fromMap(jsonDecode(value) as Map<String, dynamic>))
        .where((vector) => vector.patientId == patientId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return vectors;
  }

  Future<int> getLatestFeatureTimestampMs(String patientId) async {
    await _ready();
    return int.tryParse(_syncState.get('feature-cursor:$patientId') ?? '') ?? 0;
  }

  Future<String?> getServerUrl() async {
    await _ready();
    return _syncState.get('server_url');
  }

  Future<void> saveServerUrl(String url) async {
    await _ready();
    await _syncState.put('server_url', url);
  }

  Future<String> getUserProfile() async {
    await _ready();
    return _syncState.get('user_profile') ?? 'patient';
  }

  Future<void> setUserProfile(String profile) async {
    await _ready();
    await _syncState.put('user_profile', profile);
  }

  Future<Map<String, String>?> getPairedPatient() async {
    await _ready();
    final id = _syncState.get('paired_patient_id');
    final name = _syncState.get('paired_patient_name') ?? 'Patient';
    if (id != null && id.isNotEmpty) {
      return {'id': id, 'name': name};
    }
    return null;
  }

  Future<void> savePairedPatient(String id, String name) async {
    await _ready();
    await _syncState.put('paired_patient_id', id);
    await _syncState.put('paired_patient_name', name);
  }

  Future<void> clearPairedPatient() async {
    await _ready();
    await _syncState.delete('paired_patient_id');
    await _syncState.delete('paired_patient_name');
  }

  Future<String?> getCaretakerName() async {
    await _ready();
    return _syncState.get('caretaker_name');
  }

  Future<void> saveCaretakerName(String name) async {
    await _ready();
    await _syncState.put('caretaker_name', name);
  }
}
