import 'package:uuid/uuid.dart';
import '../models/session.dart';
import '../models/feature_measurement.dart';
import '../database/local_database.dart';
import '../sensors/sensor_service.dart';
import '../sensors/window_buffer.dart';
import '../feature_extraction/tremor_analyzer.dart';
import '../feature_extraction/bradykinesia_analyzer.dart';
import '../feature_extraction/gait_analyzer.dart';
import '../baseline/baseline_manager.dart';

class SessionManager {
  final LocalDatabase _db;
  final BaselineManager _baselineManager;
  final Uuid _uuid = const Uuid();

  SensorService? _sensorService;
  Session? _currentSession;
  
  final TremorAnalyzer _tremorAnalyzer = TremorAnalyzer();
  final BradykinesiaAnalyzer _bradykinesiaAnalyzer = BradykinesiaAnalyzer();
  final GaitAnalyzer _gaitAnalyzer = GaitAnalyzer();

  SessionManager(this._db, this._baselineManager);

  bool get isRecording => _currentSession != null;
  Session? get currentSession => _currentSession;

  Future<void> startSession(String patientId, String type, {int windowDurationMs = 5000}) async {
    if (isRecording) return;

    _currentSession = Session(
      id: _uuid.v4(),
      patientId: patientId,
      type: type,
      startTime: DateTime.now(),
    );

    await _db.createSession(_currentSession!);

    _sensorService = SensorService(
      windowDurationMs: windowDurationMs,
      onWindowFull: _processWindow,
    );
    _sensorService!.start();
  }

  void _processWindow(WindowBuffer buffer) async {
    if (_currentSession == null) return;
    
    Map<String, double> features = {};

    switch (_currentSession!.type) {
      case 'tremor':
        features = _tremorAnalyzer.extractFeatures(buffer);
        break;
      case 'bradykinesia':
        features = _bradykinesiaAnalyzer.extractFeatures(buffer);
        break;
      case 'gait':
        features = _gaitAnalyzer.extractFeatures(buffer);
        break;
    }

    if (features.isEmpty) return;

    DateTime timestamp = DateTime.now();
    List<FeatureMeasurement> measurements = [];

    features.forEach((key, value) {
      if (value.isFinite && !value.isNaN) {
        measurements.add(FeatureMeasurement(
          id: _uuid.v4(),
          sessionId: _currentSession!.id,
          patientId: _currentSession!.patientId,
          timestamp: timestamp,
          featureName: key,
          value: value,
        ));
      }
    });

    if (measurements.isNotEmpty) {
      await _db.insertMeasurements(measurements);
    }
  }

  Future<void> endSession() async {
    if (!isRecording) return;

    _sensorService?.stop();
    _sensorService = null;

    Session completedSession = _currentSession!.copyWith(endTime: DateTime.now());
    await _db.updateSession(completedSession);

    // After session ends, recalculate baselines for this patient's new features
    // In a real app, this might be done in a background isolate or on demand.
    // For prototype, we trigger it here.
    
    // Get unique feature names from the session type
    List<String> featureNames = [];
    switch (completedSession.type) {
      case 'tremor':
        featureNames = ['tremorAmplitude', 'dominantFrequency', 'tremorBandPower', 'totalPower', 'rms', 'variance', 'energy', 'tremorBandRatio'];
        break;
      case 'bradykinesia':
        featureNames = ['gyroRms', 'movementCount', 'movementFrequency', 'avgMovementAmplitude', 'movementAmplitudeVariability', 'amplitudeReduction'];
        break;
      case 'gait':
        featureNames = ['stepCount', 'cadence', 'accelRms', 'avgStepIntervalMs', 'stepIntervalVariability'];
        break;
    }

    for (var feature in featureNames) {
      await _baselineManager.recalculateBaseline(completedSession.patientId, feature);
    }

    _currentSession = null;
  }
}
