import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_feature_vector.dart';
import '../providers/app_providers.dart';
import '../sessions/processing_client.dart';
import '../theme/app_theme.dart';

class BaselineDashboardScreen extends ConsumerStatefulWidget {
  const BaselineDashboardScreen({super.key});

  @override
  ConsumerState<BaselineDashboardScreen> createState() => _BaselineDashboardScreenState();
}

class _BaselineDashboardScreenState extends ConsumerState<BaselineDashboardScreen> {
  final _processing = ProcessingClient();
  bool _loadingTestData = false;
  bool _busy = false;
  int _refreshKey = 0;

  Future<Map<String, dynamic>> _loadData(String patientId) async {
    final results = await Future.wait([
      _processing.fetchDailyReport(patientId),
      _processing.fetchBaselineStatus(patientId),
    ]);
    return {'report': results[0], 'status': results[1]};
  }

  Future<void> _finalizeBaseline(String patientId) async {
    setState(() => _busy = true);
    try {
      await _processing.finalizeBaseline(patientId);
      if (mounted) {
        setState(() => _refreshKey++);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Personal baseline frozen. Anomaly monitoring is now available.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not finalize baseline: $error'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetBaseline(String patientId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Recalibrate baseline?'),
        content: const Text(
          'This clears the frozen reference baseline and starts a fresh calibration. '
          'Historical session records and alerts are kept.',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Recalibrate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await _processing.resetBaseline(patientId);
      if (mounted) {
        setState(() => _refreshKey++);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Baseline cleared. Start baseline collection to recalibrate.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not reset baseline: $error'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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

  Future<void> _loadTestBaseline(String patientId) async {
    setState(() => _loadingTestData = true);
    try {
      await _processing.loadTestBaseline(patientId);

      // Sync the newly generated feature vectors to local Hive database
      final database = ref.read(databaseProvider);
      final vectors = await _processing.fetchFeatureVectors(patientId, afterTimestampMs: 0);
      for (final row in vectors) {
        await database.saveFeatureVector(SessionFeatureVector.fromMap(row));
      }

      if (mounted) {
        setState(() {
          _refreshKey++;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test baseline loaded with 7 calibrated intervals from ParaDigMa tutorial data.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load test baseline: $error'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingTestData = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final patient = ref.watch(currentPatientProvider);
    if (patient == null) {
      return const Scaffold(
        body: Center(child: Text('No participant selected')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Personal baseline'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            tooltip: 'Refresh baseline',
            onPressed: () => setState(() => _refreshKey++),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        key: ValueKey('baseline-$_refreshKey-${patient.id}'),
        future: _loadData(patient.id),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Could not fetch baseline: ${snapshot.error}',
                      style: const TextStyle(color: AppTheme.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: () => setState(() => _refreshKey++),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final report =
              (snapshot.data?['report'] as Map?)?.cast<String, dynamic>() ?? {};
          final status =
              (snapshot.data?['status'] as Map?)?.cast<String, dynamic>() ?? {};
          final baseline =
              (report['baseline'] as Map?)?.cast<String, dynamic>() ?? {};
          final baselineSessions = report['baseline_sessions'] ?? 0;
          final buildingSessions = status['building_sessions'] ?? 0;
          final baselineState = status['state']?.toString() ?? 'building';
          final canFinalize = status['can_finalize'] == true;
          final canMonitor = status['can_monitor'] == true;
          final minSessions = status['min_sessions'] ?? 5;
          final model = status['model']?.toString() ?? 'robust_z';

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
                        Icons.insights_rounded,
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
                    Text(
                      'Collect at least $minSessions quality baseline intervals. '
                      '$buildingSessions collected so far.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _loadingTestData ? null : () => _loadTestBaseline(patient.id),
                      icon: _loadingTestData
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.science_outlined, size: 18),
                      label: Text(_loadingTestData ? 'Calibrating test baseline…' : 'Load test baseline data'),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Loads 7 calibrated intervals from ParaDigMa\'s public PPP tutorial dataset.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textTertiary,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            baselineState == 'frozen'
                                ? Icons.lock_outline
                                : Icons.hourglass_bottom,
                            color: baselineState == 'frozen'
                                ? AppTheme.success
                                : AppTheme.warning,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              baselineState == 'frozen'
                                  ? 'Baseline frozen with $baselineSessions intervals.'
                                  : 'Baseline building: $buildingSessions of at least $minSessions intervals.',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        baselineState == 'frozen'
                            ? 'Anomaly monitoring compares new intervals with this frozen reference. '
                              'Recalibrate only after a deliberate, stable change.'
                            : 'Baseline intervals only build the reference. No alerts are generated during this phase.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.surface,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                model == 'robust_z+isolation_forest'
                                    ? 'Robust z + Isolation Forest'
                                    : 'Robust z',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (baselineState != 'frozen')
                            FilledButton(
                              onPressed: canFinalize && !_busy
                                  ? () => _finalizeBaseline(patient.id)
                                  : null,
                              child: Text(
                                _busy ? 'Finalizing…' : 'Finalize baseline',
                              ),
                            )
                          else
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _resetBaseline(patient.id),
                              child: const Text('Recalibrate baseline'),
                            ),
                        ],
                      ),
                      if (baselineState == 'frozen' && canMonitor) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Anomaly monitoring is available from the dashboard.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.success,
                          ),
                        ),
                      ],
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
