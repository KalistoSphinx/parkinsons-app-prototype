import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/local_database.dart';
import '../models/health_alert.dart';
import '../providers/app_providers.dart';
import '../services/emergency_alarm_service.dart';
import '../sessions/processing_client.dart';
import '../theme/app_theme.dart';
import '../widgets/patient_day_history_view.dart';
import '../widgets/patient_summary_view.dart';

class CaretakerScreen extends ConsumerStatefulWidget {
  const CaretakerScreen({super.key});

  @override
  ConsumerState<CaretakerScreen> createState() => _CaretakerScreenState();
}

class _CaretakerScreenState extends ConsumerState<CaretakerScreen> {
  final _processing = ProcessingClient();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  Timer? _pollingTimer;

  bool _isClaiming = false;
  bool _isAcknowledging = false;
  String? _errorMessage;

  int _currentNavIndex = 0;
  String? _selectedHistoryDate;

  Map<String, dynamic>? _activeStatus;
  List<HealthAlert> _alertHistory = const [];
  bool _alarmTriggeredForCurrentAlert = false;
  String? _lastAlarmAlertId;

  @override
  void initState() {
    super.initState();
    final existingName = ref.read(caretakerNameProvider);
    if (existingName.isNotEmpty) {
      _nameController.text = existingName;
    }
    _setupAlarmCallbacks();
    _startPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await EmergencyAlarmService.instance.requestNotificationPermission();
      await _syncCaretakerBackgroundService();
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _codeController.dispose();
    _nameController.dispose();
    EmergencyAlarmService.instance.onCaretakerAlertReceived = null;
    EmergencyAlarmService.instance.onCaretakerAlertDismissed = null;
    super.dispose();
  }

  void _setupAlarmCallbacks() {
    EmergencyAlarmService.instance.onCaretakerAlertReceived = (alert) {
      if (mounted) {
        setState(() {
          _activeStatus = {
            ...?_activeStatus,
            'active_alert': alert,
          };
        });
        _checkAndTriggerAlarm(alert);
      }
    };
    EmergencyAlarmService.instance.onCaretakerAlertDismissed = () {
      if (mounted) {
        setState(() {
          if (_activeStatus != null) {
            _activeStatus = Map<String, dynamic>.from(_activeStatus!)
              ..remove('active_alert');
          }
        });
        _alarmTriggeredForCurrentAlert = false;
        _lastAlarmAlertId = null;
      }
    };
  }

  Future<void> _syncCaretakerBackgroundService() async {
    var paired = ref.read(caretakerPairedPatientProvider);
    if (paired == null || paired['id'] == null) {
      paired = await LocalDatabase.instance.getPairedPatient();
    }
    if (paired != null && paired['id'] != null) {
      try {
        final serverUrl = await _processing.getBaseUrl();
        await EmergencyAlarmService.instance.startCaretakerMonitoring(
          patientId: paired['id']!,
          patientName: paired['name'] ?? 'Patient',
          processingUrl: serverUrl,
        );
      } catch (_) {}
    }
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _pollPatientStatus();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pollPatientStatus());
  }

  Future<void> _pollPatientStatus() async {
    final paired = ref.read(caretakerPairedPatientProvider);
    if (paired == null || paired['id'] == null) return;
    final patientId = paired['id']!;

    try {
      final status = await _processing.getActiveStatus(patientId);
      final alerts = await _processing.fetchAlerts(patientId);
      final parsedAlerts = alerts.map((m) => HealthAlert.fromMap(m)).toList();

      if (mounted) {
        setState(() {
          _activeStatus = status;
          _alertHistory = parsedAlerts;
          _errorMessage = null;
        });

        _checkAndTriggerAlarm(status['active_alert']);
      }
    } catch (e) {
      // Offline or network error
      if (mounted) {
        setState(() => _errorMessage = 'Connection error: ${e.toString()}');
      }
    }
  }

  Future<void> _checkAndTriggerAlarm(dynamic activeAlertRaw) async {
    if (activeAlertRaw != null && activeAlertRaw is Map) {
      final alertMap = Map<String, dynamic>.from(activeAlertRaw);
      final alertId = alertMap['alert_id'] as String?;
      final status = alertMap['status'] as String?;
      final title = alertMap['title'] as String? ?? 'Urgent Alert';
      final message = alertMap['message'] as String? ?? 'Immediate check on patient required';
      final symptom = alertMap['symptom'] as String? ?? 'fall';

      if (status == 'new') {
        if (!_alarmTriggeredForCurrentAlert || _lastAlarmAlertId != alertId) {
          _alarmTriggeredForCurrentAlert = true;
          _lastAlarmAlertId = alertId;
          final paired = ref.read(caretakerPairedPatientProvider);
          final serverUrl = await _processing.getBaseUrl();
          await EmergencyAlarmService.instance.startAlarm(
            alertId: alertId ?? '',
            title: title,
            message: message,
            patientName: paired?['name'] ?? 'Patient',
            symptom: symptom,
            patientId: paired?['id'] ?? '',
            processingUrl: serverUrl,
          );
        }
        return;
      } else if (status == 'acknowledged' || status == 'resolved') {
        if (_alarmTriggeredForCurrentAlert) {
          _alarmTriggeredForCurrentAlert = false;
          _lastAlarmAlertId = null;
          await EmergencyAlarmService.instance.stopAlarm();
        }
        return;
      }
    }
  }

  Future<void> _claimCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _isClaiming = true;
      _errorMessage = null;
    });

    try {
      final caretakerName = _nameController.text.trim();
      if (caretakerName.isNotEmpty) {
        await ref.read(caretakerNameProvider.notifier).setName(caretakerName);
      }
      final res = await _processing.claimPairingCode(
        code,
        caretakerName: caretakerName.isNotEmpty ? caretakerName : 'Caretaker',
      );
      final patientId = res['patient_id'] as String;
      final patientName = (res['patient_name'] as String?)?.isNotEmpty == true
          ? res['patient_name'] as String
          : 'Patient';

      await ref
          .read(caretakerPairedPatientProvider.notifier)
          .setPaired(patientId, patientName);
      await _syncCaretakerBackgroundService();
      _codeController.clear();
      await _pollPatientStatus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('StateError: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _isClaiming = false);
    }
  }

  Future<void> _acknowledgeAlert(String alertId) async {
    final paired = ref.read(caretakerPairedPatientProvider);
    if (paired == null || _isAcknowledging) return;

    setState(() => _isAcknowledging = true);
    try {
      await _processing.acknowledgeAlert(paired['id']!, alertId);
      await EmergencyAlarmService.instance.stopAlarm();
      _alarmTriggeredForCurrentAlert = false;
      _lastAlarmAlertId = null;

      if (mounted) {
        setState(() {
          // Immediately remove the emergency alarm banner from UI
          if (_activeStatus != null) {
            _activeStatus = Map<String, dynamic>.from(_activeStatus!)
              ..remove('active_alert');
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Alert acknowledged'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      await _pollPatientStatus();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isAcknowledging = false);
    }
  }

  Future<void> _silenceAlarmOnly() async {
    await EmergencyAlarmService.instance.stopAlarm();
    if (mounted) {
      setState(() => _alarmTriggeredForCurrentAlert = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Alarm ringtone silenced'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _showEditCaretakerNameDialog(String currentName) async {
    final controller = TextEditingController(text: currentName);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Caretaker Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Your Name',
            hintText: 'e.g. Sarah, Dr. John',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                Navigator.pop(ctx);
                await ref.read(caretakerNameProvider.notifier).setName(newName);
                _nameController.text = newName;
                final paired = ref.read(caretakerPairedPatientProvider);
                if (paired != null && paired['id'] != null) {
                  try {
                    await _processing.updateCaretakerProfile(paired['id']!, newName);
                  } catch (_) {}
                }
                if (mounted) setState(() {});
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _unpair() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair Patient?'),
        content: const Text(
          'You will stop receiving monitoring updates and emergency alerts from this patient until you pair again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await EmergencyAlarmService.instance.stopAlarm();
      await EmergencyAlarmService.instance.stopCaretakerMonitoring();
      _alarmTriggeredForCurrentAlert = false;
      final paired = ref.read(caretakerPairedPatientProvider);
      if (paired != null && paired['id'] != null) {
        try {
          await _processing.unpairCaretaker(paired['id']!);
        } catch (_) {}
      }
      await ref.read(caretakerPairedPatientProvider.notifier).clearPaired();
      if (mounted) {
        setState(() {
          _activeStatus = null;
          _alertHistory = [];
        });
      }
    }
  }

  void _showRoleSwitchDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch Profile'),
        content: const Text(
          'You are currently in Caretaker Mode. Would you like to switch to Patient Mode?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Stay as Caretaker'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await EmergencyAlarmService.instance.stopAlarm();
              await EmergencyAlarmService.instance.stopCaretakerMonitoring();
              ref.read(appRoleProvider.notifier).setRole(AppRole.patient);
            },
            child: const Text('Switch to Patient Mode'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, String>?>(caretakerPairedPatientProvider, (prev, next) {
      if (next != null && next['id'] != null) {
        _syncCaretakerBackgroundService();
      }
    });

    final paired = ref.watch(caretakerPairedPatientProvider);

    Widget bodyContent;
    if (paired == null) {
      bodyContent = _buildPairingView();
    } else {
      final caretakerName = ref.watch(caretakerNameProvider);
      final displayName = caretakerName.isNotEmpty ? caretakerName : 'Caretaker';

      Widget tabView;
      switch (_currentNavIndex) {
        case 1:
          tabView = PatientDayHistoryView(
            key: ValueKey(_selectedHistoryDate),
            patientId: paired['id']!,
            initialDate: _selectedHistoryDate,
            authorName: 'Caretaker ($displayName)',
            onDateChanged: (d) => _selectedHistoryDate = d,
          );
          break;
        case 2:
          tabView = PatientSummaryView(
            patientId: paired['id']!,
            onDateSelected: (date) {
              setState(() {
                _selectedHistoryDate = date;
                _currentNavIndex = 1;
              });
            },
          );
          break;
        default:
          tabView = _buildDashboardView(paired);
          break;
      }

      final activeAlert = _activeStatus?['active_alert'];
      if (activeAlert != null && _currentNavIndex != 0) {
        bodyContent = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _buildEmergencyAlarmBanner(activeAlert),
            ),
            Expanded(child: tabView),
          ],
        );
      } else {
        bodyContent = tabView;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'CARETAKER',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primary,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(paired != null ? (paired['name'] ?? 'Patient') : 'Caretaker Portal'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Switch Profile',
            icon: const Icon(Icons.swap_horiz),
            onPressed: _showRoleSwitchDialog,
          ),
          if (paired != null)
            IconButton(
              tooltip: 'Unpair Patient',
              icon: const Icon(Icons.link_off),
              onPressed: _unpair,
            ),
        ],
      ),
      body: bodyContent,
      bottomNavigationBar: paired == null
          ? null
          : NavigationBar(
              selectedIndex: _currentNavIndex,
              onDestinationSelected: (i) => setState(() => _currentNavIndex = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.sensors_outlined),
                  selectedIcon: Icon(Icons.sensors),
                  label: 'Live & Today',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history),
                  label: 'Day History',
                ),
                NavigationDestination(
                  icon: Icon(Icons.analytics_outlined),
                  selectedIcon: Icon(Icons.analytics),
                  label: 'Summary',
                ),
              ],
            ),
    );
  }

  Widget _buildPairingView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.supervisor_account,
                size: 36,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Connect with a Patient',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ask the patient to tap "Connect Caretaker" on their device and enter their 6-digit one-time code below.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Your Name (Caretaker)',
                        hintText: 'e.g. Sarah, Dr. John',
                        prefixIcon: Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Patient Pairing Code',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 7,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]')),
                      ],
                      style: const TextStyle(
                        fontSize: 28,
                        letterSpacing: 6,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: const InputDecoration(
                        hintText: '123-456',
                        counterText: '',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppTheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isClaiming ? null : _claimCode,
                        icon: _isClaiming
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.link, size: 20),
                        label: Text(_isClaiming ? 'Connecting...' : 'Connect to Patient'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
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

  Widget _buildDashboardView(Map<String, String> paired) {
    final status = _activeStatus;
    final isOnline = status?['online'] == true;
    final activeAlert = status?['active_alert'];
    final labels = (status?['symptom_labels'] as Map<String, dynamic>?) ?? {};
    final dayReport = status?['day_report'] as Map<String, dynamic>?;
    final baselineState = status?['baseline_state'] as Map<String, dynamic>?;
    final caretakerName = ref.watch(caretakerNameProvider);
    final displayName = caretakerName.isNotEmpty ? caretakerName : 'Caretaker';

    return RefreshIndicator(
      onRefresh: _pollPatientStatus,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCaretakerProfileHeader(displayName),
          const SizedBox(height: 12),
          _buildOnlineStatusCard(paired, isOnline, status?['last_seen_ms']),
          const SizedBox(height: 12),
          if (activeAlert != null) ...[
            _buildEmergencyAlarmBanner(activeAlert),
            const SizedBox(height: 16),
          ],
          _buildObservationSection(labels, dayReport),
          const SizedBox(height: 16),
          _buildBaselineOverviewCard(baselineState),
          const SizedBox(height: 16),
          _buildAlertsHistorySection(),
        ],
      ),
    );
  }

  Widget _buildCaretakerProfileHeader(String name) {
    return Card(
      elevation: 0,
      color: AppTheme.primary.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary,
              child: Icon(Icons.health_and_safety, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CARETAKER PROFILE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: AppTheme.primary,
                    ),
                  ),
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _showEditCaretakerNameDialog(name),
              icon: const Icon(Icons.edit, size: 14),
              label: const Text('Edit', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineStatusCard(
    Map<String, String> paired,
    bool isOnline,
    dynamic lastSeenMs,
  ) {
    String timeAgo = 'No data yet';
    if (lastSeenMs != null && lastSeenMs is num && lastSeenMs > 0) {
      final diff = DateTime.now().millisecondsSinceEpoch - lastSeenMs.toInt();
      final seconds = diff ~/ 1000;
      final minutes = seconds ~/ 60;
      if (minutes < 1) {
        timeAgo = 'Active just now';
      } else if (minutes < 60) {
        timeAgo = '$minutes min ago';
      } else {
        timeAgo = '${minutes ~/ 60}h ago';
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
              child: const Icon(Icons.person, color: AppTheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    paired['name'] ?? 'Patient',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isOnline ? AppTheme.success : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isOnline ? 'Online • $timeAgo' : 'Offline • $timeAgo',
                        style: TextStyle(
                          fontSize: 12,
                          color: isOnline ? AppTheme.success : AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh now',
              onPressed: _pollPatientStatus,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyAlarmBanner(Map<String, dynamic> alert) {
    final alertId = alert['alert_id'] as String? ?? '';
    final title = alert['title'] as String? ?? 'Urgent Alert';
    final message = alert['message'] as String? ?? '';
    final symptom = alert['symptom'] as String? ?? '';
    final isFall = symptom == 'fall';

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.error, width: 2),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: AppTheme.error,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isFall ? Icons.personal_injury : Icons.warning_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: const TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Emergency Ringtone Sounding',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(fontSize: 14, height: 1.3),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _silenceAlarmOnly,
                  icon: const Icon(Icons.volume_off, size: 18),
                  label: const Text('Silence Sound'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.error,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _isAcknowledging ? null : () => _acknowledgeAlert(alertId),
                  icon: _isAcknowledging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check, size: 18),
                  label: Text(_isAcknowledging ? 'Acknowledging...' : 'Acknowledge'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildObservationSection(
    Map<String, dynamic> labels,
    Map<String, dynamic>? dayReport,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  "Patient's Live Condition",
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _observationRow(
              'Tremor',
              labels['tremor']?.toString() ?? 'insufficient data',
              Icons.vibration,
            ),
            const Divider(height: 16),
            _observationRow(
              'Gait & arm swing',
              labels['gait']?.toString() ?? 'insufficient data',
              Icons.directions_walk,
            ),
            const Divider(height: 16),
            _observationRow(
              'Movement vigor proxy',
              labels['bradykinesia_proxy']?.toString() ?? 'insufficient data',
              Icons.speed,
            ),
            const Divider(height: 16),
            Builder(
              builder: (context) {
                final fallStatus = labels['fall']?.toString() ?? 'normal';
                final isCriticalFall = fallStatus == 'critical';
                final isAckFall = fallStatus == 'acknowledged';
                return _observationRow(
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
                  _statItem('${dayReport?['processed_sessions'] ?? 0}', 'Intervals'),
                  _statItem('${dayReport?['monitoring_minutes'] ?? 0}m', 'Coverage'),
                  _statItem('${dayReport?['fall_incidents'] ?? 0}', 'Falls'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _observationRow(
    String title,
    String status,
    IconData icon, {
    String? displayOverride,
  }) {
    Color badgeColor;
    Color textColor;
    switch (status) {
      case 'normal':
        badgeColor = AppTheme.success.withValues(alpha: 0.12);
        textColor = AppTheme.success;
        break;
      case 'acknowledged':
        badgeColor = const Color(0xFFFEF3C7);
        textColor = const Color(0xFFB45309);
        break;
      case 'mild':
        badgeColor = const Color(0xFFE0F2FE);
        textColor = const Color(0xFF0369A1);
        break;
      case 'moderate':
        badgeColor = AppTheme.warning.withValues(alpha: 0.12);
        textColor = AppTheme.warning;
        break;
      case 'severe':
      case 'critical':
        badgeColor = AppTheme.error.withValues(alpha: 0.12);
        textColor = AppTheme.error;
        break;
      default:
        badgeColor = AppTheme.surfaceSubtle;
        textColor = AppTheme.textSecondary;
    }

    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: badgeColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            displayOverride ?? status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
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
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildBaselineOverviewCard(Map<String, dynamic>? baselineState) {
    final isCalibrated = baselineState?['state'] == 'frozen';
    final sessions = isCalibrated
        ? (baselineState?['reference_sessions'] ?? 0)
        : (baselineState?['building_sessions'] ?? 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isCalibrated
                    ? AppTheme.success.withValues(alpha: 0.12)
                    : AppTheme.warning.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isCalibrated ? Icons.verified : Icons.construction,
                color: isCalibrated ? AppTheme.success : AppTheme.warning,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isCalibrated ? 'Personal Baseline Calibrated' : 'Baseline Building',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isCalibrated
                        ? 'Using $sessions personal reference intervals for anomaly detection'
                        : '$sessions / 5 quality baseline intervals collected',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertsHistorySection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Alert History',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            if (_alertHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No alerts recorded for this patient.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _alertHistory.take(10).length,
                separatorBuilder: (context, index) => const Divider(height: 16),
                itemBuilder: (context, index) {
                  final alert = _alertHistory[index];
                  final isResolved = alert.status == 'resolved';
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        alert.severity == 'critical'
                            ? Icons.error_outline
                            : Icons.warning_amber_rounded,
                        color: alert.severity == 'critical'
                            ? AppTheme.error
                            : AppTheme.warning,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alert.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              alert.message,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isResolved
                              ? AppTheme.surfaceSubtle
                              : AppTheme.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isResolved ? 'Resolved' : alert.status.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isResolved
                                ? AppTheme.textSecondary
                                : AppTheme.warning,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
