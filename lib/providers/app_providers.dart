import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/local_database.dart';
import '../models/patient.dart';

final databaseProvider = Provider<LocalDatabase>((ref) {
  return LocalDatabase.instance;
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
