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
  
  void setPatient(Patient? patient) {
    state = patient;
  }

  void clear() {
    state = null;
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

enum AppRole { patient, caretaker }

class AppRoleNotifier extends Notifier<AppRole> {
  @override
  AppRole build() {
    LocalDatabase.instance.getUserProfile().then((val) {
      state = val == 'caretaker' ? AppRole.caretaker : AppRole.patient;
    });
    return AppRole.patient;
  }

  Future<void> setRole(AppRole role) async {
    state = role;
    await LocalDatabase.instance.setUserProfile(role.name);
  }
}

final appRoleProvider = NotifierProvider<AppRoleNotifier, AppRole>(() {
  return AppRoleNotifier();
});

class CaretakerPairedPatientNotifier extends Notifier<Map<String, String>?> {
  @override
  Map<String, String>? build() {
    LocalDatabase.instance.getPairedPatient().then((val) {
      state = val;
    });
    return null;
  }

  Future<void> setPaired(String id, String name) async {
    state = {'id': id, 'name': name};
    await LocalDatabase.instance.savePairedPatient(id, name);
  }

  Future<void> clearPaired() async {
    state = null;
    await LocalDatabase.instance.clearPairedPatient();
  }
}

final caretakerPairedPatientProvider =
    NotifierProvider<CaretakerPairedPatientNotifier, Map<String, String>?>(() {
  return CaretakerPairedPatientNotifier();
});

class CaretakerNameNotifier extends Notifier<String> {
  @override
  String build() {
    LocalDatabase.instance.getCaretakerName().then((val) {
      if (val != null && val.isNotEmpty) {
        state = val;
      }
    });
    return '';
  }

  Future<void> setName(String name) async {
    state = name.trim();
    await LocalDatabase.instance.saveCaretakerName(state);
  }
}

final caretakerNameProvider = NotifierProvider<CaretakerNameNotifier, String>(() {
  return CaretakerNameNotifier();
});
