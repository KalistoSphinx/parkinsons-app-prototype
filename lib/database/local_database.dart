import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/patient.dart';
import '../models/session.dart';
import '../models/feature_measurement.dart';
import '../models/baseline.dart';

class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._init();
  static Database? _database;

  LocalDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('parkinsons_prototype.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE patients (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        patientId TEXT NOT NULL,
        type TEXT NOT NULL,
        startTime TEXT NOT NULL,
        endTime TEXT,
        FOREIGN KEY (patientId) REFERENCES patients (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE feature_measurements (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        patientId TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        featureName TEXT NOT NULL,
        value REAL NOT NULL,
        FOREIGN KEY (sessionId) REFERENCES sessions (id),
        FOREIGN KEY (patientId) REFERENCES patients (id)
      )
    ''');

    // Indexes for querying efficiency
    await db.execute('CREATE INDEX idx_measurements_patient_feature ON feature_measurements (patientId, featureName)');
    await db.execute('CREATE INDEX idx_measurements_session ON feature_measurements (sessionId)');

    await db.execute('''
      CREATE TABLE baselines (
        id TEXT PRIMARY KEY,
        patientId TEXT NOT NULL,
        featureName TEXT NOT NULL,
        mean REAL NOT NULL,
        median REAL NOT NULL,
        std REAL NOT NULL,
        min REAL NOT NULL,
        max REAL NOT NULL,
        p05 REAL NOT NULL,
        p25 REAL NOT NULL,
        p75 REAL NOT NULL,
        p95 REAL NOT NULL,
        sampleCount INTEGER NOT NULL,
        lastUpdated TEXT NOT NULL,
        FOREIGN KEY (patientId) REFERENCES patients (id)
      )
    ''');
    await db.execute('CREATE UNIQUE INDEX idx_baseline_patient_feature ON baselines (patientId, featureName)');
  }

  // --- Patients ---
  Future<void> createPatient(Patient patient) async {
    final db = await instance.database;
    await db.insert('patients', patient.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Patient>> getPatients() async {
    final db = await instance.database;
    final result = await db.query('patients');
    return result.map((json) => Patient.fromMap(json)).toList();
  }

  // --- Sessions ---
  Future<void> createSession(Session session) async {
    final db = await instance.database;
    await db.insert('sessions', session.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSession(Session session) async {
    final db = await instance.database;
    await db.update(
      'sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  Future<List<Session>> getSessions(String patientId) async {
    final db = await instance.database;
    final result = await db.query(
      'sessions',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'startTime DESC',
    );
    return result.map((json) => Session.fromMap(json)).toList();
  }

  // --- Feature Measurements ---
  Future<void> insertMeasurements(List<FeatureMeasurement> measurements) async {
    final db = await instance.database;
    final batch = db.batch();
    for (var m in measurements) {
      batch.insert('feature_measurements', m.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<List<FeatureMeasurement>> getMeasurements(String patientId, {String? featureName}) async {
    final db = await instance.database;
    List<Map<String, dynamic>> result;
    if (featureName != null) {
      result = await db.query(
        'feature_measurements',
        where: 'patientId = ? AND featureName = ?',
        whereArgs: [patientId, featureName],
        orderBy: 'timestamp ASC',
      );
    } else {
      result = await db.query(
        'feature_measurements',
        where: 'patientId = ?',
        whereArgs: [patientId],
        orderBy: 'timestamp ASC',
      );
    }
    return result.map((json) => FeatureMeasurement.fromMap(json)).toList();
  }

  Future<List<FeatureMeasurement>> getAllMeasurements() async {
    final db = await instance.database;
    final result = await db.query('feature_measurements', orderBy: 'timestamp ASC');
    return result.map((json) => FeatureMeasurement.fromMap(json)).toList();
  }

  // --- Baselines ---
  Future<void> saveBaseline(Baseline baseline) async {
    final db = await instance.database;
    // Handle replace using unique index
    await db.insert(
      'baselines',
      baseline.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Baseline>> getBaselines(String patientId) async {
    final db = await instance.database;
    final result = await db.query(
      'baselines',
      where: 'patientId = ?',
      whereArgs: [patientId],
    );
    return result.map((json) => Baseline.fromMap(json)).toList();
  }

  Future<Baseline?> getBaseline(String patientId, String featureName) async {
    final db = await instance.database;
    final result = await db.query(
      'baselines',
      where: 'patientId = ? AND featureName = ?',
      whereArgs: [patientId, featureName],
    );
    if (result.isNotEmpty) {
      return Baseline.fromMap(result.first);
    }
    return null;
  }
}
