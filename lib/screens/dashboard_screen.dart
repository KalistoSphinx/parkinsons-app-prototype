import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import 'test_screen.dart';
import 'baseline_dashboard_screen.dart';
import '../utils/csv_exporter.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentPatient = ref.watch(currentPatientProvider);

    if (currentPatient == null) {
      return const Scaffold(body: Center(child: Text('No patient selected')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Dashboard: ${currentPatient.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: () async {
               final db = ref.read(databaseProvider);
               final file = await CsvExporter.exportMeasurements(db, currentPatient.id);
               if (context.mounted && file != null) {
                 ScaffoldMessenger.of(context).showSnackBar(
                   SnackBar(content: Text('Exported to ${file.path}')),
                 );
               }
            },
            tooltip: 'Export CSV',
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildActionCard(
            context, 
            'Tremor Test', 
            'Hold phone steadily in hand', 
            Icons.vibration, 
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TestScreen(testType: 'tremor')))
          ),
          _buildActionCard(
            context, 
            'Bradykinesia Test', 
            'Perform rapid alternating movements', 
            Icons.waving_hand, 
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TestScreen(testType: 'bradykinesia')))
          ),
          _buildActionCard(
            context, 
            'Gait Test', 
            'Walk for a few meters with phone in pocket', 
            Icons.directions_walk, 
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TestScreen(testType: 'gait')))
          ),
          const Divider(height: 32),
          _buildActionCard(
            context, 
            'View Baselines', 
            'See personalized baseline statistics', 
            Icons.analytics, 
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BaselineDashboardScreen()))
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard(BuildContext context, String title, String subtitle, IconData icon, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: Icon(icon, size: 40, color: Theme.of(context).primaryColor),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
