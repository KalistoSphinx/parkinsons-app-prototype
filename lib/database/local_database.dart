import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

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
  late Box<String> _syncState;

  Future<void> initialize() => _initializing ??= _open();

  Future<void> _open() async {
    final directory = await getApplicationSupportDirectory();
    Hive.init(directory.path);
    _patients = await Hive.openBox<String>('patients');
    _features = await Hive.openBox<String>('session_features');
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
}
