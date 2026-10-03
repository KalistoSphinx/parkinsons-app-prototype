import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import '../providers/app_providers.dart';
import 'dashboard_screen.dart';

class PatientSelectionScreen extends ConsumerWidget {
  const PatientSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patientsAsyncValue = ref.watch(patientsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Select Patient')),
      body: patientsAsyncValue.when(
        data: (patients) {
          if (patients.isEmpty) {
            return const Center(child: Text('No patients found. Please create one.'));
          }
          return ListView.builder(
            itemCount: patients.length,
            itemBuilder: (context, index) {
              final patient = patients[index];
              return ListTile(
                title: Text(patient.name),
                subtitle: Text('ID: ${patient.id}'),
                onTap: () {
                  ref.read(currentPatientProvider.notifier).setPatient(patient);
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => const DashboardScreen()),
                  );
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddPatientDialog(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddPatientDialog(BuildContext context, WidgetRef ref) {
    final TextEditingController nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add New Patient'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Patient Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isNotEmpty) {
                  final db = ref.read(databaseProvider);
                  final patient = Patient(
                    id: const Uuid().v4(),
                    name: name,
                    createdAt: DateTime.now(),
                  );
                  await db.createPatient(patient);
                  ref.invalidate(patientsProvider); // Refresh list
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }
}
