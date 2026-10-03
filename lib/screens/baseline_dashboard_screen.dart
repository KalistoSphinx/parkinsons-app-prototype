import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../models/baseline.dart';

class BaselineDashboardScreen extends ConsumerWidget {
  const BaselineDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(currentPatientProvider);
    
    if (patient == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('No patient')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Personal Baselines')),
      body: FutureBuilder<List<Baseline>>(
        future: ref.read(databaseProvider).getBaselines(patient.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          
          final baselines = snapshot.data ?? [];
          if (baselines.isEmpty) {
            return const Center(
              child: Text(
                'No baseline data yet.\nPerform tests to build baseline.',
                textAlign: TextAlign.center,
              )
            );
          }

          return ListView.builder(
            itemCount: baselines.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (context, index) {
              final b = baselines[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.featureName, 
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                      ),
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Mean: ${b.mean.toStringAsFixed(4)}'),
                          Text('StdDev: ${b.std.toStringAsFixed(4)}'),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Samples: ${b.sampleCount}'),
                          Text('Last updated: ${b.lastUpdated.toLocal().toString().split('.')[0]}'),
                        ],
                      )
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
