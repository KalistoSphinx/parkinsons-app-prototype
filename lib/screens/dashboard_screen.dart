import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/health_alert.dart';
import '../models/session_feature_vector.dart';
import '../providers/app_providers.dart';
import '../sessions/continuous_monitor_controller.dart';
import '../sessions/processing_client.dart';
import '../sessions/server_discovery.dart';
import '../theme/app_theme.dart';
import 'baseline_dashboard_screen.dart';
import 'patient_records_screen.dart';

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
  StreamSubscription? _monitoringUpdateSubscription;
  bool _refreshing = false;
  bool _monitoring = false;
  bool _busy = false;
  bool _loadingTestData = false;
  Map<String, dynamic>? _report;
  Map<String, dynamic>? _baselineStatus;
  List<HealthAlert> _alerts = const [];
  String? _monitoringMode;
  String? _error;
  String? _serverUrl;
  bool _serverHealthy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ContinuousMonitorController.initializeChannel();
    _monitoringUpdateSubscription =
        ContinuousMonitorController.onMonitoringUpdate.listen((_) {
      if (mounted) _refresh();
    });
    // Periodic sync timer: 20 seconds while monitoring is active; background service pushes instant updates via onMonitoringUpdate
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _monitoring) {
        _refresh();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _monitoringUpdateSubscription?.cancel();
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    final patient = ref.read(currentPatientProvider);
    if (patient == null) return;

    _refreshing = true;
    try {
      final detectedUrl = await ServerDiscovery.instance.discoverServerUrl();
      final isHealthy = (_serverHealthy && _serverUrl == detectedUrl)
          ? true
          : await ServerDiscovery.instance.checkHealth(detectedUrl);
      if (mounted) {
        setState(() {
          _serverUrl = detectedUrl;
          _serverHealthy = isHealthy;
        });
      }

      bool? isRunning;
      String? statusError;
      MonitoringMode? mode;
      try {
        isRunning = await _monitor.isMonitoring(patient.id);
        mode = await _monitor.currentMode(patient.id);
      } catch (error) {
        statusError = error.toString();
      }

      try {
        final baselineStatus = await _processing.fetchBaselineStatus(patient.id);
        final alertRows = await _processing.fetchAlerts(patient.id);
        final database = ref.read(databaseProvider);
        for (final row in alertRows) {
          await database.saveAlert(HealthAlert.fromMap(row));
        }
        final localAlerts = await database.getAlerts(patient.id);

        final report = await _processing.fetchDailyReport(patient.id);
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
            _baselineStatus = baselineStatus;
            _alerts = localAlerts;
            _monitoring = isRunning ?? _monitoring;
            _monitoringMode = isRunning == true ? (mode?.wireName ?? _monitoringMode) : null;
            _error = statusError;
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _monitoring = isRunning ?? _monitoring;
            _monitoringMode = isRunning == true ? (mode?.wireName ?? _monitoringMode) : null;
            _error = statusError == null ? error.toString() : '$statusError\n$error';
          });
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _toggleMonitoring(
    String patientId,
    MonitoringMode mode,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sameMode = _monitoring && _monitoringMode == mode.wireName;
      if (sameMode) {
        await _monitor.stop();
        if (mounted) {
          setState(() {
            _monitoring = false;
            _monitoringMode = null;
          });
        }
      } else {
        if (mode == MonitoringMode.anomaly &&
            _baselineStatus?['can_monitor'] != true) {
          throw StateError(
            'Collect at least ${_baselineStatus?['min_sessions'] ?? 5} '
            'baseline intervals before starting anomaly monitoring.',
          );
        }
        // Switching modes stops the old service first and starts a clean batch.
        await _monitor.start(patientId, mode: mode);
        if (mounted) {
          setState(() {
            _monitoring = true;
            _monitoringMode = mode.wireName;
          });
        }
      }
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismissAlert(HealthAlert alert, {String reason = 'false_positive'}) async {
    try {
      await _processing.dismissAlert(alert.patientId, alert.alertId, reason: reason);
      await ref.read(databaseProvider).acknowledgeAlert(alert.patientId, alert.alertId);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Alert shut down and marked as false positive. Caretaker notified.'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _loadTestBaseline(String patientId) async {
    setState(() => _loadingTestData = true);
    try {
      await _processing.loadTestBaseline(patientId);
      final database = ref.read(databaseProvider);
      final vectors = await _processing.fetchFeatureVectors(patientId, afterTimestampMs: 0);
      for (final row in vectors) {
        await database.saveFeatureVector(SessionFeatureVector.fromMap(row));
      }
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test baseline data loaded (7 quality intervals ready for review and calibration)'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to load test baseline: $e');
    } finally {
      if (mounted) setState(() => _loadingTestData = false);
    }
  }

  Future<void> _finalizeBaseline(String patientId) async {
    setState(() => _busy = true);
    try {
      await _processing.finalizeBaseline(patientId);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Personal baseline finalized and calibrated!'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to finalize baseline: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPairingCodeDialog(
    BuildContext context,
    String patientId,
    String patientName,
  ) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _PairingCodeDialog(
        patientId: patientId,
        patientName: patientName,
        processing: _processing,
      ),
    );
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
      case 'acknowledged':
        return const Color(0xFFD97706);
      case 'mild':
      case 'warning':
        return AppTheme.warning;
      case 'moderate':
      case 'severe':
      case 'critical':
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
    final baselineState = _baselineStatus?['state']?.toString() ?? 'building';
    final canMonitor = _baselineStatus?['can_monitor'] == true;
    final buildingSessions = _baselineStatus?['building_sessions'] ?? baselineSessions;
    final minSessions = _baselineStatus?['min_sessions'] ?? 5;
    final openAlerts = _alerts.where((alert) => alert.isOpen).toList();
    final newAlerts = openAlerts
        .where((alert) =>
            alert.status == 'new' &&
            (alert.severity == 'warning' || alert.severity == 'critical'))
        .toList();
    final baselineActive = _monitoring && _monitoringMode == 'baseline';
    final anomalyActive = _monitoring && _monitoringMode == 'anomaly';

    return Scaffold(
      appBar: AppBar(
        title: Text(patient.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Connect Caretaker',
            onPressed: () => _showPairingCodeDialog(context, patient.id, patient.name),
          ),
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 22),
            onSelected: (value) {
              if (value == 'delete') {
                _confirmDeleteCurrentPatient(context, patient);
              } else if (value == 'switch_role') {
                ref.read(appRoleProvider.notifier).setRole(AppRole.caretaker);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'switch_role',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 18, color: AppTheme.primary),
                    SizedBox(width: 8),
                    Text('Switch to Caretaker Mode'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
                    SizedBox(width: 8),
                    Text('Delete participant', style: TextStyle(color: AppTheme.error)),
                  ],
                ),
              ),
            ],
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
            if (newAlerts.isNotEmpty) ...[
              _alertBanner(context, newAlerts.first),
              const SizedBox(height: 14),
            ],

            _buildPairingCard(patient),
            const SizedBox(height: 14),

            // Feature 1: baseline creation
            _monitoringCard(
              context,
              title: 'Personal baseline',
              subtitle: baselineState == 'frozen'
                  ? 'Frozen with $baselineSessions reference intervals. Recalibrate from the baseline screen to collect a new reference.'
                  : 'Collecting reference intervals: $buildingSessions of at least $minSessions.',
              icon: Icons.foundation_outlined,
              accent: AppTheme.primary,
              active: baselineActive,
              enabled: !_busy && (baselineState != 'frozen' || baselineActive),
              buttonLabel: baselineActive
                  ? 'Stop baseline collection'
                  : baselineState == 'frozen'
                      ? 'Baseline frozen'
                      : 'Start baseline collection',
              onPressed: () => _toggleMonitoring(patient.id, MonitoringMode.baseline),
              footer: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BaselineDashboardScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.tune, size: 16),
                    label: Text(
                      baselineState == 'frozen'
                          ? 'View baseline details'
                          : 'Review baseline details',
                    ),
                  ),
                  if (baselineState != 'frozen')
                    TextButton.icon(
                      onPressed: _loadingTestData ? null : () => _loadTestBaseline(patient.id),
                      icon: _loadingTestData
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.science_outlined, size: 16),
                      label: Text(_loadingTestData ? 'Loading…' : 'Load test data'),
                    ),
                  if (baselineState != 'frozen' && buildingSessions >= minSessions)
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: _busy ? null : () => _finalizeBaseline(patient.id),
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Finalize baseline'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Feature 2: anomaly monitoring against the frozen baseline
            _monitoringCard(
              context,
              title: 'Anomaly monitoring',
              subtitle: canMonitor
                  ? 'Compare every interval with the personal baseline and generate an alert when it changes.'
                  : 'Finalize a baseline with at least $minSessions intervals before starting anomaly monitoring.',
              icon: Icons.notifications_active_outlined,
              accent: AppTheme.warning,
              active: anomalyActive,
              enabled: !_busy && (canMonitor || anomalyActive),
              buttonLabel: anomalyActive
                  ? 'Stop anomaly monitoring'
                  : 'Start anomaly monitoring',
              onPressed: () => _toggleMonitoring(patient.id, MonitoringMode.anomaly),
              footer: Text(
                'Left wrist · 3-minute windows',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
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
                    const Divider(height: 20),
                    Builder(
                      builder: (context) {
                        final fallLabel = labels['fall']?.toString() ?? 'normal';
                        final isCriticalFall = fallLabel == 'critical';
                        final isAckFall = fallLabel == 'acknowledged';
                        return _observationRow(
                          context,
                          'Fall monitoring',
                          isCriticalFall ? 'critical' : (isAckFall ? 'acknowledged' : 'normal'),
                          Icons.personal_injury,
                          displayOverride: isCriticalFall
                              ? 'FALL DETECTED'
                              : (isAckFall ? 'Fall Acknowledged' : 'Normal (no falls)'),
                        );
                      },
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
            if (_alerts.isNotEmpty) ...[
              const SizedBox(height: 14),
              _alertHistoryCard(context),
            ],
            const SizedBox(height: 14),

            // Day-to-Day History, Notes & Summaries
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PatientRecordsScreen(
                      patientId: patient.id,
                      patientName: patient.name,
                      authorName: patient.name,
                    ),
                  ),
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
                          Icons.calendar_month_outlined,
                          color: AppTheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Day-to-Day History & Notes',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Review past observations, clinical notes & weekly summaries',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: AppTheme.textSecondary,
                        size: 20,
                      ),
                    ],
                  ),
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
                                  : 'Building baseline… (tap to load test data)',
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

  Widget _alertBanner(BuildContext context, HealthAlert alert) {
    final isFall = alert.symptom == 'fall' || alert.title.toLowerCase().contains('fall');
    final color = isFall ? AppTheme.error : _statusColor(alert.severity);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isFall ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: isFall ? 0.60 : 0.35), width: isFall ? 1.5 : 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isFall ? Icons.personal_injury : Icons.warning_amber_rounded, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  alert.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isFall ? AppTheme.error.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isFall ? 'FALL EMERGENCY' : alert.severity.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            alert.message,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                isFall
                    ? 'Sudden fall detected · Caretaker notified'
                    : (alert.severity == 'critical'
                        ? 'Immediate critical alert · Caretaker notified'
                        : 'Confirmed in 2 of the last 3 intervals'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isFall ? FontWeight.w600 : FontWeight.normal,
                  color: color,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _dismissAlert(alert, reason: 'false_positive'),
                style: FilledButton.styleFrom(
                  foregroundColor: AppTheme.error,
                  backgroundColor: AppTheme.error.withValues(alpha: 0.12),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                icon: const Icon(Icons.check_circle_outline, size: 15),
                label: const Text("I'm OK / False Alarm", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _monitoringCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accent,
    required bool active,
    required bool enabled,
    required String buttonLabel,
    required VoidCallback onPressed,
    required Widget footer,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? AppTheme.success : AppTheme.textTertiary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  active ? 'Active' : 'Paused',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: active ? AppTheme.success : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: active
                    ? FilledButton.styleFrom(
                        backgroundColor: AppTheme.error,
                        foregroundColor: Colors.white,
                      )
                    : FilledButton.styleFrom(backgroundColor: accent),
                onPressed: enabled ? onPressed : null,
                icon: Icon(active ? Icons.stop : Icons.play_arrow, size: 20),
                label: Text(buttonLabel),
              ),
            ),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: footer),
          ],
        ),
      ),
    );
  }

  Widget _alertHistoryCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Alert history',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${_alerts.where((alert) => alert.isOpen).length} open',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ..._alerts.take(6).map((alert) {
              final isFall = alert.symptom == 'fall' || alert.title.toLowerCase().contains('fall');
              final color = isFall ? AppTheme.error : _statusColor(alert.severity);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  isFall
                      ? Icons.personal_injury
                      : (alert.isOpen
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline),
                  size: 20,
                  color: color,
                ),
                title: Text(
                  alert.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isFall ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${alert.severity.toUpperCase()} · ${alert.status}',
                  style: TextStyle(fontSize: 11, color: color),
                ),
                trailing: alert.isOpen
                    ? TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => _dismissAlert(alert, reason: 'false_positive'),
                        child: const Text('False Alarm', style: TextStyle(fontSize: 11, color: AppTheme.error)),
                      )
                    : null,
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _observationRow(
    BuildContext context,
    String title,
    String value,
    IconData icon, {
    String? displayOverride,
  }) {
    final color = _statusColor(value);
    final displayText = displayOverride ?? value;
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
          displayText,
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

  Widget _buildPairingCard(dynamic patient) {
    final caretaker = _report?['caretaker'] as Map<String, dynamic>?;
    final isPaired = caretaker != null &&
        (caretaker['caretaker_name'] as String?)?.isNotEmpty == true;

    if (isPaired) {
      final caretakerName = caretaker['caretaker_name'] as String;
      return Card(
        color: AppTheme.success.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppTheme.success.withValues(alpha: 0.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.verified_user, color: AppTheme.success, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Caretaker: $caretakerName',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.success.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Connected',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Receiving live observations & alerts',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20, color: AppTheme.textSecondary),
                tooltip: 'Caretaker options',
                onSelected: (val) {
                  if (val == 'code') {
                    _showPairingCodeDialog(context, patient.id, patient.name);
                  } else if (val == 'unpair') {
                    _confirmUnpairCaretaker(patient, caretakerName);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'code',
                    child: Row(
                      children: [
                        Icon(Icons.qr_code, size: 18),
                        SizedBox(width: 8),
                        Text('Show Pairing Code'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'unpair',
                    child: Row(
                      children: [
                        Icon(Icons.link_off, size: 18, color: AppTheme.error),
                        SizedBox(width: 8),
                        Text('Unpair Caretaker', style: TextStyle(color: AppTheme.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.people_alt_outlined, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Caretaker Connection',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'No caretaker connected • Tap to link',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _showPairingCodeDialog(context, patient.id, patient.name),
              icon: const Icon(Icons.link, size: 16),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmUnpairCaretaker(dynamic patient, String caretakerName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect Caretaker "$caretakerName"?'),
        content: const Text(
          'Your caretaker will no longer receive monitoring observations or emergency alerts until you reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _processing.unpairCaretaker(patient.id);
                await _refresh();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Disconnected caretaker "$caretakerName"'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Unpairing failed: $e')),
                  );
                }
              }
            },
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteCurrentPatient(BuildContext context, dynamic patient) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete participant?'),
        content: Text(
          'Are you sure you want to delete ${patient.name}? This will remove their record and personal baseline.',
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () async {
              Navigator.pop(ctx);
              ref.read(currentPatientProvider.notifier).clear();
              await ref.read(databaseProvider).deletePatient(patient.id);
              await _processing.deletePatient(patient.id);
              ref.invalidate(patientsProvider);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Participant "${patient.name}" deleted'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _PairingCodeDialog extends StatefulWidget {
  final String patientId;
  final String patientName;
  final ProcessingClient processing;

  const _PairingCodeDialog({
    required this.patientId,
    required this.patientName,
    required this.processing,
  });

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  bool _loading = true;
  String? _code;
  int _remainingSeconds = 900;
  Timer? _countdownTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchCode();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchCode() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final active = await widget.processing.getActivePairingCode(widget.patientId);
      Map<String, dynamic> pairingData;
      if (active['active'] == true && active['pairing'] != null) {
        pairingData = active['pairing'] as Map<String, dynamic>;
      } else {
        pairingData = await widget.processing.generatePairingCode(
          widget.patientId,
          patientName: widget.patientName,
          ttlSeconds: 900,
        );
      }

      final code = pairingData['code'] as String;
      final remaining = (pairingData['expires_in_seconds'] as num?)?.toInt() ?? 900;

      if (mounted) {
        setState(() {
          _code = code;
          _remainingSeconds = remaining;
          _loading = false;
        });
        _startTimer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not generate pairing code: $e';
          _loading = false;
        });
      }
    }
  }

  void _startTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSeconds <= 1) {
        timer.cancel();
        setState(() {
          _remainingSeconds = 0;
          _code = null;
        });
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  String _formatTimer(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatCode(String raw) {
    if (raw.length == 6) {
      return '${raw.substring(0, 3)} - ${raw.substring(3)}';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.link, color: AppTheme.primary, size: 22),
          ),
          const SizedBox(width: 12),
          const Text('Connect Caretaker', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Share this 6-digit one-time code with your caretaker. They can enter it in the Caretaker Portal on their phone to connect over long range.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 13)),
            )
          else if (_code != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSubtle,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3), width: 1.5),
              ),
              child: Column(
                children: [
                  Text(
                    _formatCode(_code!),
                    style: const TextStyle(
                      fontSize: 32,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.timer_outlined, size: 14, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        'Expires in ${_formatTimer(_remainingSeconds)}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _code!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pairing code copied to clipboard'), duration: Duration(seconds: 2)),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy code'),
            ),
          ] else ...[
            const Text('Code expired.', style: TextStyle(color: AppTheme.error)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _fetchCode,
              child: const Text('Generate new code'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
