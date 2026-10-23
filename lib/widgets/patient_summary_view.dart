import 'package:flutter/material.dart';

import '../sessions/processing_client.dart';
import '../theme/app_theme.dart';

class PatientSummaryView extends StatefulWidget {
  final String patientId;
  final ValueChanged<String>? onDateSelected;

  const PatientSummaryView({
    super.key,
    required this.patientId,
    this.onDateSelected,
  });

  @override
  State<PatientSummaryView> createState() => _PatientSummaryViewState();
}

class _PatientSummaryViewState extends State<PatientSummaryView> {
  final _processing = ProcessingClient();

  String _window = 'weekly'; // 'weekly' or 'monthly'
  Map<String, dynamic>? _summary;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await _processing.fetchPeriodSummary(
        widget.patientId,
        window: _window,
      );
      if (mounted) {
        setState(() {
          _summary = res;
          _loading = false;
        });
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

  Color _severityColor(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'critical':
        return AppTheme.error;
      case 'warning':
        return AppTheme.warning;
      case 'normal':
      case 'stable':
        return AppTheme.success;
      default:
        return AppTheme.primary;
    }
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
        _buildWindowSelector(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildErrorView()
                  : RefreshIndicator(
                      onRefresh: _loadSummary,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        children: [
                          _buildTrajectoryCard(),
                          const SizedBox(height: 14),
                          _buildAggregatesGrid(),
                          const SizedBox(height: 14),
                          _buildDailyBreakdownSection(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildWindowSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'weekly',
            label: Text('Weekly (7 Days)'),
            icon: Icon(Icons.view_week_outlined, size: 16),
          ),
          ButtonSegment(
            value: 'monthly',
            label: Text('Monthly (30 Days)'),
            icon: Icon(Icons.calendar_month_outlined, size: 16),
          ),
        ],
        selected: {_window},
        onSelectionChanged: (newSelection) {
          if (newSelection.isNotEmpty && newSelection.first != _window) {
            setState(() => _window = newSelection.first);
            _loadSummary();
          }
        },
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
            const Text(
              'Could not load period summary',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? 'Network error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadSummary,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrajectoryCard() {
    final sum = _summary;
    final trajectory = sum?['trajectory']?.toString() ?? 'Stable Motor Function';
    final severity = sum?['trajectory_severity']?.toString() ?? 'normal';
    final narrative = sum?['clinical_narrative']?.toString() ?? '';
    final color = _severityColor(severity);

    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    severity == 'critical'
                        ? Icons.warning_rounded
                        : severity == 'warning'
                            ? Icons.info_outline
                            : Icons.check_circle_outline,
                    color: color,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'OVERALL PERIOD TRAJECTORY',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        trajectory,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (narrative.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                narrative,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAggregatesGrid() {
    final sum = _summary;
    final daysMonitored = sum?['days_monitored'] ?? 0;
    final daysInWindow = sum?['days_in_window'] ?? (_window == 'weekly' ? 7 : 30);
    final adherencePct = (sum?['adherence_pct'] as num?)?.toDouble() ?? 0.0;
    final totalMinutes = (sum?['total_monitoring_minutes'] as num?)?.toDouble() ?? 0.0;
    final totalHours = (totalMinutes / 60).toStringAsFixed(1);
    final daysTremor = sum?['days_with_tremor'] ?? 0;
    final falls = sum?['total_fall_incidents'] ?? 0;

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.7,
      children: [
        _metricTile(
          title: 'Adherence',
          value: '$daysMonitored of $daysInWindow d',
          subtitle: '$adherencePct% tracked days',
          icon: Icons.calendar_today_outlined,
          color: AppTheme.primary,
        ),
        _metricTile(
          title: 'Total Monitored',
          value: '${totalHours}h',
          subtitle: '${totalMinutes.toInt()} minutes recorded',
          icon: Icons.schedule,
          color: AppTheme.primary,
        ),
        _metricTile(
          title: 'Tremor Days',
          value: '$daysTremor d',
          subtitle: daysTremor > 0 ? 'Tremor activity noted' : 'No tremor alerts',
          icon: Icons.vibration,
          color: daysTremor > 0 ? AppTheme.warning : AppTheme.success,
        ),
        _metricTile(
          title: 'Fall Incidents',
          value: '$falls',
          subtitle: falls > 0 ? 'Urgent attention required' : 'Zero falls reported',
          icon: Icons.personal_injury,
          color: falls > 0 ? AppTheme.error : AppTheme.success,
        ),
      ],
    );
  }

  Widget _metricTile({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
                ),
                Icon(icon, size: 16, color: color),
              ],
            ),
            Text(
              value,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyBreakdownSection() {
    final sum = _summary;
    final breakdownRaw = (sum?['daily_breakdown'] as List<dynamic>?) ?? [];
    // Display in reverse order (newest day first)
    final breakdown = breakdownRaw.reversed.map((e) => Map<String, dynamic>.from(e as Map)).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Day-by-Day Motor Timeline',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap any day to view complete observations, notes, and alerts',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 14),
            if (breakdown.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text('No monitoring intervals recorded in this window.', style: TextStyle(color: AppTheme.textSecondary)),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: breakdown.length,
                separatorBuilder: (context, index) => const Divider(height: 12),
                itemBuilder: (ctx, i) {
                  final day = breakdown[i];
                  final dateStr = day['date']?.toString() ?? '';
                  final dayName = day['day_name']?.toString() ?? '';
                  final monitored = day['monitored'] == true;
                  final overall = day['overall_status']?.toString() ?? 'insufficient data';
                  final durMin = (day['monitoring_minutes'] as num?)?.toDouble() ?? 0.0;
                  final falls = (day['fall_incidents'] as num?)?.toInt() ?? 0;
                  final notesCount = (day['notes_count'] as num?)?.toInt() ?? 0;
                  final symLabels = (day['symptom_labels'] as Map<String, dynamic>?) ?? {};
                  final tremorLbl = symLabels['tremor']?.toString() ?? 'normal';
                  final gaitLbl = symLabels['gait']?.toString() ?? 'normal';

                  final statusColor = _statusColor(overall);

                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      if (widget.onDateSelected != null) {
                        widget.onDateSelected!(dateStr);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 72,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  dayName,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                                Text(
                                  dateStr.length >= 10 ? dateStr.substring(5) : dateStr,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        overall,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: statusColor,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      monitored ? '${durMin.toInt()}m' : 'Off',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: monitored ? AppTheme.textPrimary : AppTheme.textTertiary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    if (tremorLbl != 'normal' && tremorLbl != 'insufficient data')
                                      _miniBadge(Icons.vibration, 'Tremor', AppTheme.warning),
                                    if (gaitLbl != 'normal' && gaitLbl != 'insufficient data')
                                      _miniBadge(Icons.directions_walk, 'Gait', AppTheme.warning),
                                    if (falls > 0)
                                      _miniBadge(Icons.warning, '$falls Fall${falls > 1 ? 's' : ''}', AppTheme.error),
                                    if (notesCount > 0)
                                      _miniBadge(Icons.note_alt, '$notesCount', AppTheme.primary),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right, size: 18, color: AppTheme.textTertiary),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniBadge(IconData icon, String label, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}
