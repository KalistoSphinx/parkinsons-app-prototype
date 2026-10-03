import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';

class TestScreen extends ConsumerStatefulWidget {
  final String testType;
  
  const TestScreen({super.key, required this.testType});

  @override
  ConsumerState<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends ConsumerState<TestScreen> {
  bool _isRecording = false;
  int _secondsElapsed = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startRecording() async {
    final patient = ref.read(currentPatientProvider);
    if (patient == null) return;

    final sessionManager = ref.read(sessionManagerProvider);
    await sessionManager.startSession(patient.id, widget.testType);

    setState(() {
      _isRecording = true;
      _secondsElapsed = 0;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _secondsElapsed++;
      });
    });
  }

  void _stopRecording() async {
    final sessionManager = ref.read(sessionManagerProvider);
    await sessionManager.endSession();
    
    _timer?.cancel();
    setState(() {
      _isRecording = false;
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test completed and data saved')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    String title = '${widget.testType[0].toUpperCase()}${widget.testType.substring(1)} Test';
    
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _isRecording ? 'Recording...' : 'Ready to record',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            if (_isRecording)
              Text(
                '$_secondsElapsed seconds',
                style: const TextStyle(fontSize: 48, color: Colors.red),
              ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : _startRecording,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRecording ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
              ),
              child: Text(
                _isRecording ? 'STOP' : 'START',
                style: const TextStyle(fontSize: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
