import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_feature_vector.dart';
import '../providers/app_providers.dart';
import '../sessions/continuous_monitor_controller.dart';
import '../sessions/processing_client.dart';
import '../sessions/server_discovery.dart';
import '../theme/app_theme.dart';
import 'baseline_dashboard_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WidgetsBindingObserver {
  final _monitor = ContinuousMonitorController();
  final _processing = ProcessingClient();
  Timer? _refreshTimer;
  bool _monitoring = false;
  bool _busy = false;
  Map<String, dynamic>? _report;
  String? _error;
  String? _serverUrl;
  bool _serverHealthy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final patient = ref.read(currentPatientProvider);
    if (patient == null || !mounted) return;

    final detectedUrl = await ServerDiscovery.instance.discoverServerUrl();
    final isHealthy = await ServerDiscovery.instance.checkHealth(detectedUrl);
    if (mounted) {
      setState(() {
        _serverUrl = detectedUrl;
        _serverHealthy = isHealthy;
      });
    }

    bool? isRunning;
    String? statusError;
    try {
      isRunning = await _monitor.isMonitoring();
    } catch (error) {
      statusError = error.toString();
    }
    if (mounted && isRunning != null) {
      setState(() => _monitoring = isRunning!);
    }
    try {
      final report = await _processing.fetchDailyReport(patient.id);
      final database = ref.read(databaseProvider);
      var cursor = await database.getLatestFeatureTimestampMs(patient.id);
      while (true) {
        final vectors = await _processing.fetchFeatureVectors(
          patient.id,
          afterTimestampMs: cursor,
        );
        for (final row in vectors) {
          final vector = SessionFeatureVector.fromMap(row);
          await database.saveFeatureVector(vector);
          cursor = vector.timestamp.millisecondsSinceEpoch > cursor
              ? vector.timestamp.millisecondsSinceEpoch
              : cursor;
        }
        if (vectors.length < 500) break;
      }
      if (mounted) {
        setState(() {
          _report = report;
          _error = statusError;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = statusError == null ? error.toString() : '$statusError\n$error');
      }
    }
  }

  Future<void> _toggleMonitoring(String patientId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_monitoring) {
        await _monitor.stop();
      } else {
        await _monitor.start(patientId);
      }
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showServerSettings(BuildContext context) {
    final controller = TextEditingController(text: _serverUrl ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Backend connection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The server IP is discovered automatically on your Wi-Fi network. You can also specify an override address:',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.xxx:8000',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newUrl = controller.text.trim();
              if (newUrl.isNotEmpty) {
                await ServerDiscovery.instance.setManualUrl(newUrl);
                if (ctx.mounted) Navigator.pop(ctx);
                _refresh();
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String? label) {
    switch (label?.toLowerCase()) {
      case 'normal':
        return AppTheme.success;
      case 'mild':
        return AppTheme.warning;
      case 'moderate':
      case 'severe':
        return AppTheme.error;
      default:
        return AppTheme.textSecondary;
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

    final report = _report;
    final labels = (report?['symptom_labels'] as Map?)?.cast<String, dynamic>() ?? {};
    final processed = report?['processed_sessions'] ?? 0;
    final baselineSessions = report?['baseline_sessions'] ?? 0;
    final overall = report?['overall_status']?.toString() ?? 'baseline building';

    return Scaffold(
      appBar: AppBar(
        title: Text(patient.name),
        actions: [
          // Connection status pill in the AppBar
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Icon(
                _serverHealthy ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                color: _serverHealthy ? AppTheme.success : AppTheme.warning,
                size: 22,
              ),
              tooltip: _serverHealthy
                  ? 'Connected to server (${_serverUrl ?? ""})'
                  : 'Server unreachable. Tap to configure.',
              onPressed: () => _showServerSettings(context),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.errorLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(fontSize: 12, color: AppTheme.error),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16, color: AppTheme.error),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => setState(() => _error = null),
                    ),
                  ],
                ),
              ),
            ],
            // Hero: Monitoring State & Action
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _monitoring ? AppTheme.success : AppTheme.textTertiary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _monitoring ? 'Monitoring active' : 'Monitoring paused',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _monitoring ? AppTheme.success : AppTheme.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSubtle,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Left wrist',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _monitoring
                          ? 'Continuous collection in progress'
                          : 'Ready to capture motion',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _monitoring
                          ? '3-minute sensor windows are automatically analyzed and uploaded to build the baseline.'
                          : 'Wear device firmly on left wrist and begin recording daily mobility signals.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: _monitoring
                            ? FilledButton.styleFrom(
                                backgroundColor: AppTheme.error,
                                foregroundColor: Colors.white,
                              )
                            : null,
                        onPressed: _busy ? null : () => _toggleMonitoring(patient.id),
                        icon: Icon(
                          _monitoring ? Icons.stop : Icons.play_arrow,
                          size: 20,
                        ),
                        label: Text(_busy
                            ? 'Updating…'
                            : _monitoring
                                ? 'Stop monitoring'
                                : 'Start all-day monitoring'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Today's Clinical Observation Summary
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "Today's observations",
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _statusColor(overall).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            overall,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _statusColor(overall),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _observationRow(
                      context,
                      'Tremor',
                      labels['tremor']?.toString() ?? 'insufficient data',
                      Icons.vibration,
                    ),
                    const Divider(height: 20),
                    _observationRow(
                      context,
                      'Gait & arm swing',
                      labels['gait']?.toString() ?? 'insufficient data',
                      Icons.directions_walk,
                    ),
                    const Divider(height: 20),
                    _observationRow(
                      context,
                      'Movement vigor proxy',
                      labels['bradykinesia_proxy']?.toString() ?? 'insufficient data',
                      Icons.speed,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceSubtle,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _statItem('$processed', 'Intervals today'),
                          _statItem('$baselineSessions', 'In baseline'),
                          _statItem(
                            '${report?['monitoring_minutes'] ?? 0}m',
                            'Coverage',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Navigation to Personal Baseline
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BaselineDashboardScreen()),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.bar_chart_rounded,
                          color: AppTheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Personal baseline',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              baselineSessions > 0
                                  ? '$baselineSessions calibrated intervals'
                                  : 'Building baseline…',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: AppTheme.textTertiary,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Quiet Minimal Server Link
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _showServerSettings(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _serverHealthy ? Icons.link : Icons.link_off,
                      size: 14,
                      color: _serverHealthy ? AppTheme.textSecondary : AppTheme.warning,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _serverHealthy
                          ? 'Connected: ${_serverUrl ?? "Local server"}'
                          : 'Server offline: tap to discover',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _observationRow(
    BuildContext context,
    String title,
    String value,
    IconData icon,
  ) {
    final color = _statusColor(value);
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _statItem(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}
