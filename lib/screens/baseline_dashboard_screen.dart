import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../sessions/processing_client.dart';
import '../theme/app_theme.dart';

class BaselineDashboardScreen extends ConsumerWidget {
  const BaselineDashboardScreen({super.key});

  String _formatFeatureName(String key) {
    switch (key) {
      case 'tremor_probability':
        return 'Tremor probability';
      case 'tremor_power':
        return 'Tremor spectral power';
      case 'tremor_time':
        return 'Tremor duration ratio';
      case 'gait_probability':
        return 'Gait probability';
      case 'arm_swing_rom':
        return 'Arm swing range of motion';
      case 'arm_swing_peak_velocity':
        return 'Arm swing peak velocity';
      case 'accel_rms_m_s2':
        return 'Acceleration RMS (m/s²)';
      case 'gyro_rms_rad_s':
        return 'Gyroscope RMS (rad/s)';
      default:
        return key.replaceAll('_', ' ');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(currentPatientProvider);
    if (patient == null) {
      return const Scaffold(
        body: Center(child: Text('No participant selected')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Personal baseline'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: ProcessingClient().fetchDailyReport(patient.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2.5),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not fetch baseline: ${snapshot.error}',
                  style: const TextStyle(color: AppTheme.error, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final baseline = (snapshot.data?['baseline'] as Map?)?.cast<String, dynamic>() ?? {};
          final baselineSessions = snapshot.data?['baseline_sessions'] ?? 0;

          if (baseline.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceSubtle,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Icon(
                        Icons.insights,
                        size: 28,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Baseline is building',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Personal baseline statistics will automatically calculate after quality-checked monitoring intervals are processed.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              Card(
                color: AppTheme.surfaceSubtle,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_outline,
                        color: AppTheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Calibrated across $baselineSessions quality monitoring intervals.',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ...baseline.entries.map((entry) {
                final stats = (entry.value as Map).cast<String, dynamic>();
                final mean = (stats['mean'] as num).toDouble();
                final std = (stats['std'] as num).toDouble();
                final median = (stats['median'] as num).toDouble();
                final p05 = (stats['p05'] as num).toDouble();
                final p95 = (stats['p95'] as num).toDouble();
                final count = stats['count'] ?? 0;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _formatFeatureName(entry.key),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceSubtle,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'N=$count',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              mean.toStringAsFixed(3),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '± ${std.toStringAsFixed(3)}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Median ${median.toStringAsFixed(3)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSubtle,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '5th %ile: ${p05.toStringAsFixed(3)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              Text(
                                '95th %ile: ${p95.toStringAsFixed(3)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
