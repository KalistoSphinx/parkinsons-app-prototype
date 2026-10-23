import 'package:flutter/material.dart';

import '../models/health_alert.dart';
import '../sessions/processing_client.dart';
import '../theme/app_theme.dart';

class PatientDayHistoryView extends StatefulWidget {
  final String patientId;
  final String? initialDate;
  final String authorName;
  final ValueChanged<String>? onDateChanged;

  const PatientDayHistoryView({
    super.key,
    required this.patientId,
    this.initialDate,
    this.authorName = 'Caretaker',
    this.onDateChanged,
  });

  @override
  State<PatientDayHistoryView> createState() => _PatientDayHistoryViewState();
}

class _PatientDayHistoryViewState extends State<PatientDayHistoryView> {
  final _processing = ProcessingClient();

  late String _currentDate;
  List<String> _availableDates = [];
  Map<String, dynamic>? _report;
  List<Map<String, dynamic>> _notes = [];
  List<HealthAlert> _alerts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentDate = widget.initialDate ?? _todayIso();
    _loadDatesAndReport();
  }

  @override
  void didUpdateWidget(covariant PatientDayHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDate != null &&
        widget.initialDate != _currentDate &&
        widget.initialDate != oldWidget.initialDate) {
      _currentDate = widget.initialDate!;
      _loadReportForDate(_currentDate);
    }
  }

  String _todayIso() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadDatesAndReport() async {
    setState(() => _loading = true);
    try {
      final dates = await _processing.fetchHistoryDates(widget.patientId);
      if (mounted) {
        setState(() {
          _availableDates = dates.isEmpty ? [_todayIso()] : dates;
          if (!_availableDates.contains(_currentDate)) {
            _availableDates.insert(0, _currentDate);
            _availableDates.sort((a, b) => b.compareTo(a));
          }
        });
      }
      await _loadReportForDate(_currentDate);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('StateError: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadReportForDate(String targetDate) async {
    setState(() {
      _loading = true;
      _error = null;
      _currentDate = targetDate;
    });

    try {
      final rep = await _processing.fetchDailyReport(widget.patientId, date: targetDate);
      final rawNotes = (rep['notes'] as List<dynamic>?) ?? [];
      final rawAlerts = (rep['alerts'] as List<dynamic>?) ?? [];

      if (mounted) {
        setState(() {
          _report = rep;
          _notes = rawNotes.map((n) => Map<String, dynamic>.from(n as Map)).toList();
          _alerts = rawAlerts.map((a) => HealthAlert.fromMap(a as Map<String, dynamic>)).toList();
          _loading = false;
        });
        widget.onDateChanged?.call(targetDate);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('StateError: ', '');
          _loading = false;
        });
      }
    }
  }

  void _stepDate(int deltaDays) {
    try {
      final dt = DateTime.parse(_currentDate);
      final newDt = dt.add(Duration(days: deltaDays));
      final now = DateTime.now();
      final todayDt = DateTime(now.year, now.month, now.day);
      if (newDt.isAfter(todayDt)) return; // Cannot step into future

      final newIso = '${newDt.year.toString().padLeft(4, '0')}-'
          '${newDt.month.toString().padLeft(2, '0')}-'
          '${newDt.day.toString().padLeft(2, '0')}';
      _loadReportForDate(newIso);
    } catch (_) {}
  }

  Future<void> _pickDateFromCalendar() async {
    final now = DateTime.now();
    DateTime initial;
    try {
      initial = DateTime.parse(_currentDate);
    } catch (_) {
      initial = now;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now) ? now : initial,
      firstDate: DateTime(2024, 1, 1),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppTheme.primary,
              onPrimary: Colors.white,
              onSurface: AppTheme.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final iso = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
      _loadReportForDate(iso);
    }
  }

  Future<void> _showAddNoteDialog() async {
    final textController = TextEditingController();
    final selectedTags = <String>{'General'};
    final availableTags = ['General', 'Medication', 'Symptoms', 'Mobility', 'Fatigue', 'Nutrition'];

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.note_alt_outlined, color: AppTheme.primary, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text('Add Clinical Note', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Date: ${_formatDisplayDate(_currentDate)}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: textController,
                      maxLines: 4,
                      minLines: 3,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Given 100mg Levodopa at 09:00. Patient observed slight hand tremor while holding cup.',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text('Tags / Categories:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: availableTags.map((tag) {
                        final isSelected = selectedTags.contains(tag);
                        return FilterChip(
                          selected: isSelected,
                          label: Text(tag, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : AppTheme.textPrimary)),
                          selectedColor: AppTheme.primary,
                          checkmarkColor: Colors.white,
                          onSelected: (val) {
                            setDialogState(() {
                              if (val) {
                                selectedTags.add(tag);
                              } else {
                                if (selectedTags.length > 1) {
                                  selectedTags.remove(tag);
                                }
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final text = textController.text.trim();
                    if (text.isEmpty) return;
                    Navigator.pop(ctx);
                    await _submitNewNote(text, selectedTags.toList());
                  },
                  child: const Text('Save Note'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submitNewNote(String text, List<String> tags) async {
    try {
      final res = await _processing.addNote(
        widget.patientId,
        date: _currentDate,
        text: text,
        tags: tags,
        author: widget.authorName,
      );
      if (mounted && res['note'] != null) {
        setState(() {
          _notes.insert(0, Map<String, dynamic>.from(res['note'] as Map));
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clinical note saved'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save note: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteNote(String noteId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Note?'),
        content: const Text('Are you sure you want to delete this clinical note?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _processing.deleteNote(widget.patientId, noteId);
      if (mounted) {
        setState(() {
          _notes.removeWhere((n) => n['note_id'] == noteId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note deleted'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete note: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  String _formatDisplayDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final now = DateTime.now();
      final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final yesterday = now.subtract(const Duration(days: 1));
      final isYesterday = dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day;

      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

      if (isToday) return 'Today, ${months[dt.month - 1]} ${dt.day}';
      if (isYesterday) return 'Yesterday, ${months[dt.month - 1]} ${dt.day}';
      return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  bool get _isToday {
    return _currentDate == _todayIso();
  }

  Color _statusColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('fall') || s.contains('critical') || s.contains('severe')) {
      return AppTheme.error;
    }
    if (s.contains('tremor') || s.contains('gait') || s.contains('warning') || s.contains('mild') || s.contains('watch')) {
      return AppTheme.warning;
    }
    if (s.contains('stable') || s.contains('normal')) {
      return AppTheme.success;
    }
    return AppTheme.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildDateNavigatorBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildErrorView()
                  : RefreshIndicator(
                      onRefresh: () => _loadReportForDate(_currentDate),
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        children: [
                          _buildOverallStatusCard(),
                          const SizedBox(height: 14),
                          _buildSymptomsCard(),
                          const SizedBox(height: 14),
                          _buildAdditionalReadingsCard(),
                          const SizedBox(height: 14),
                          _buildNotesSection(),
                          const SizedBox(height: 14),
                          _buildAlertHistorySection(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildDateNavigatorBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 28),
            tooltip: 'Previous day',
            onPressed: () => _stepDate(-1),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _pickDateFromCalendar,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.calendar_today, size: 16, color: AppTheme.primary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _formatDisplayDate(_currentDate),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary, size: 20),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 28),
            tooltip: 'Next day',
            onPressed: _isToday ? null : () => _stepDate(1),
          ),
          if (!_isToday)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                label: const Text('Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                backgroundColor: AppTheme.primaryLight,
                labelStyle: const TextStyle(color: AppTheme.primary),
                onPressed: () => _loadReportForDate(_todayIso()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 12),
            Text(
              'Could not load data for $_currentDate',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(_error ?? 'Network error', textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _loadReportForDate(_currentDate),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverallStatusCard() {
    final rep = _report;
    final overall = rep?['overall_status']?.toString() ?? 'insufficient data';
    final processed = rep?['processed_sessions'] ?? 0;
    final minutes = rep?['monitoring_minutes'] ?? 0;
    final falls = rep?['fall_incidents'] ?? 0;
    final color = _statusColor(overall);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'OVERALL MOTOR STATUS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        overall.toUpperCase(),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        falls > 0
                            ? Icons.warning_amber_rounded
                            : processed > 0
                                ? Icons.check_circle_outline
                                : Icons.hourglass_empty,
                        size: 16,
                        color: color,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        processed > 0 ? '$processed intervals' : 'No data',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSubtle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statItem('$processed', 'Sessions'),
                  _statItem('${minutes}m', 'Coverage'),
                  _statItem(
                    '$falls',
                    'Fall events',
                    highlightColor: falls > 0 ? AppTheme.error : null,
                  ),
                  _statItem('${_notes.length}', 'Notes'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String value, String label, {Color? highlightColor}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: highlightColor ?? AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildSymptomsCard() {
    final rep = _report;
    final labels = (rep?['symptom_labels'] as Map<String, dynamic>?) ?? {};
    final tremor = labels['tremor']?.toString() ?? 'insufficient data';
    final gait = labels['gait']?.toString() ?? 'insufficient data';
    final vigor = labels['bradykinesia_proxy']?.toString() ?? 'insufficient data';
    final fall = labels['fall']?.toString() ?? 'normal';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Observed Motor Symptoms',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 12),
            _symptomRow('Rest Tremor', tremor, Icons.vibration),
            const Divider(height: 16),
            _symptomRow('Gait & Arm Swing', gait, Icons.directions_walk),
            const Divider(height: 16),
            _symptomRow('Movement Vigor', vigor, Icons.speed),
            const Divider(height: 16),
            _symptomRow(
              'Fall Monitoring',
              fall == 'critical' ? 'FALL DETECTED' : (fall == 'acknowledged' ? 'Acknowledged' : 'Normal'),
              Icons.personal_injury,
            ),
          ],
        ),
      ),
    );
  }

  Widget _symptomRow(String title, String status, IconData icon) {
    final color = _statusColor(status);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            status,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildAdditionalReadingsCard() {
    final rep = _report;
    final readings = (rep?['additional_readings'] as Map<String, dynamic>?) ?? {};

    final tremorBurden = (readings['tremor_burden_pct'] as num?)?.toDouble() ?? 0.0;
    final vigorRatio = (readings['movement_vigor_ratio'] as num?)?.toDouble() ?? 1.0;
    final activePct = (readings['active_movement_pct'] as num?)?.toDouble() ?? 0.0;
    final restPct = (readings['rest_pct'] as num?)?.toDouble() ?? 100.0;
    final fallCount = (readings['fall_count'] as num?)?.toInt() ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.query_stats, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Key Clinical Readings',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
              children: [
                _clinicalMetricBox(
                  label: 'Tremor Burden',
                  value: '$tremorBurden%',
                  subtext: tremorBurden > 10.0 ? 'Elevated activity' : 'Within normal limits',
                  color: tremorBurden > 10.0 ? AppTheme.warning : AppTheme.success,
                  icon: Icons.waves,
                ),
                _clinicalMetricBox(
                  label: 'Movement Vigor',
                  value: '${vigorRatio.toStringAsFixed(2)}x',
                  subtext: vigorRatio < 0.8 ? 'Bradykinesia flag' : 'Normal amplitude',
                  color: vigorRatio < 0.8 ? AppTheme.warning : AppTheme.success,
                  icon: Icons.electric_bolt,
                ),
                _clinicalMetricBox(
                  label: 'Active vs Rest',
                  value: '${activePct.toInt()}% / ${restPct.toInt()}%',
                  subtext: 'Active mobility ratio',
                  color: AppTheme.primary,
                  icon: Icons.accessibility_new,
                ),
                _clinicalMetricBox(
                  label: 'Fall Triggers',
                  value: '$fallCount',
                  subtext: fallCount > 0 ? 'Requires attention' : 'No abrupt impacts',
                  color: fallCount > 0 ? AppTheme.error : AppTheme.success,
                  icon: Icons.warning_rounded,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _clinicalMetricBox({
    required String label,
    required String value,
    required String subtext,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(icon, size: 14, color: color),
            ],
          ),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
          ),
          Text(
            subtext,
            style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildNotesSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Clinical Notes',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: _showAddNoteDialog,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Note', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_notes.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceSubtle,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'No notes recorded for this date. Tap "+ Add Note" to log medication, symptoms, or caregiver observations.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _notes.length,
                separatorBuilder: (context, index) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  final note = _notes[i];
                  final noteId = note['note_id'] as String? ?? '';
                  final text = note['text'] as String? ?? '';
                  final author = note['author'] as String? ?? 'Caretaker';
                  final created = note['created_at'] as String? ?? '';
                  final tags = (note['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];

                  String timeStr = '';
                  if (created.length >= 16) {
                    timeStr = created.substring(11, 16);
                  }

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceSubtle,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 10,
                              backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                              child: const Icon(Icons.person, size: 12, color: AppTheme.primary),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              author,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                            ),
                            if (timeStr.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text('• $timeStr', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ],
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.textTertiary),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _deleteNote(noteId),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          text,
                          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.4),
                        ),
                        if (tags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: tags.map((tag) {
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  tag,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.primary),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertHistorySection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_none, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Alerts on this Date',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _alerts.isNotEmpty ? AppTheme.errorLight : AppTheme.surfaceSubtle,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_alerts.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _alerts.isNotEmpty ? AppTheme.error : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_alerts.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceSubtle,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'No alerts recorded on this date.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _alerts.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) {
                  final alert = _alerts[i];
                  final isCritical = alert.severity == 'critical';
                  final color = isCritical ? AppTheme.error : AppTheme.warning;

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isCritical ? Icons.emergency : Icons.warning_amber_rounded,
                          color: color,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      alert.title,
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      alert.status.toUpperCase(),
                                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                alert.message,
                                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                alert.formattedTime,
                                style: const TextStyle(fontSize: 10, color: AppTheme.textTertiary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
