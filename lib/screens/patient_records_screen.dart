import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/patient_day_history_view.dart';
import '../widgets/patient_summary_view.dart';

class PatientRecordsScreen extends StatefulWidget {
  final String patientId;
  final String patientName;
  final String? initialDate;
  final String authorName;

  const PatientRecordsScreen({
    super.key,
    required this.patientId,
    required this.patientName,
    this.initialDate,
    this.authorName = 'Patient',
  });

  @override
  State<PatientRecordsScreen> createState() => _PatientRecordsScreenState();
}

class _PatientRecordsScreenState extends State<PatientRecordsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _selectedDate;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _selectedDate = widget.initialDate;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onDateSelectedFromSummary(String date) {
    setState(() {
      _selectedDate = date;
    });
    _tabController.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Patient History & Summaries', style: TextStyle(fontSize: 16)),
            Text(
              widget.patientName,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          indicatorColor: AppTheme.primary,
          tabs: const [
            Tab(icon: Icon(Icons.history, size: 20), text: 'Day History & Notes'),
            Tab(icon: Icon(Icons.analytics_outlined, size: 20), text: 'Trends & Summary'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          PatientDayHistoryView(
            key: ValueKey(_selectedDate),
            patientId: widget.patientId,
            initialDate: _selectedDate,
            authorName: widget.authorName,
            onDateChanged: (d) => _selectedDate = d,
          ),
          PatientSummaryView(
            patientId: widget.patientId,
            onDateSelected: _onDateSelectedFromSummary,
          ),
        ],
      ),
    );
  }
}
