import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/local_database.dart';
import '../baseline/baseline_manager.dart';
import '../sessions/session_manager.dart';
import '../models/patient.dart';

final databaseProvider = Provider<LocalDatabase>((ref) {
  return LocalDatabase.instance;
});

final baselineManagerProvider = Provider<BaselineManager>((ref) {
  return BaselineManager(ref.watch(databaseProvider));
});

final sessionManagerProvider = Provider<SessionManager>((ref) {
  return SessionManager(ref.watch(databaseProvider), ref.watch(baselineManagerProvider));
});

// StateNotifier to hold the currently selected patient
class CurrentPatientNotifier extends Notifier<Patient?> {
  @override
  Patient? build() => null;
  
  void setPatient(Patient patient) {
    state = patient;
  }
}

final currentPatientProvider = NotifierProvider<CurrentPatientNotifier, Patient?>(() {
  return CurrentPatientNotifier();
});

// Provider to fetch all patients
final patientsProvider = FutureProvider<List<Patient>>((ref) async {
  final db = ref.watch(databaseProvider);
  return db.getPatients();
});
