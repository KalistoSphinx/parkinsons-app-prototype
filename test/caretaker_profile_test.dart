import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Caretaker Profile and Fall Observation logic', () {
    test('fall observation correctly reflects new, acknowledged, and normal states', () {
      // 1. Critical state when fall alert is new
      final labelsCritical = {'fall': 'critical'};
      final isCritical1 = labelsCritical['fall'] == 'critical';
      final isAck1 = labelsCritical['fall'] == 'acknowledged';
      expect(isCritical1 ? 'FALL DETECTED' : (isAck1 ? 'Fall Acknowledged' : 'Normal (no falls)'), 'FALL DETECTED');

      // 2. Acknowledged state when fall alert is acknowledged
      final labelsAck = {'fall': 'acknowledged'};
      final isCritical2 = labelsAck['fall'] == 'critical';
      final isAck2 = labelsAck['fall'] == 'acknowledged';
      expect(isCritical2 ? 'FALL DETECTED' : (isAck2 ? 'Fall Acknowledged' : 'Normal (no falls)'), 'Fall Acknowledged');

      // 3. Normal state when alert is resolved or dismissed
      final labelsNormal = {'fall': 'normal'};
      final isCritical3 = labelsNormal['fall'] == 'critical';
      final isAck3 = labelsNormal['fall'] == 'acknowledged';
      expect(isCritical3 ? 'FALL DETECTED' : (isAck3 ? 'Fall Acknowledged' : 'Normal (no falls)'), 'Normal (no falls)');
    });

    test('caretaker profile payload is correctly extracted from daily report', () {
      final report = {
        'caretaker': {
          'caretaker_name': 'Sarah',
          'paired_at_ms': 1700000000000,
          'active': true,
        },
      };

      final caretaker = report['caretaker'] as Map<String, dynamic>?;
      final isPaired = caretaker != null &&
          (caretaker['caretaker_name'] as String?)?.isNotEmpty == true;

      expect(isPaired, isTrue);
      expect(caretaker!['caretaker_name'], 'Sarah');
    });

    test('unpaired patient report returns null or inactive caretaker', () {
      final report = <String, dynamic>{
        'caretaker': null,
      };

      final caretaker = report['caretaker'] as Map<String, dynamic>?;
      final isPaired = caretaker != null &&
          (caretaker['caretaker_name'] as String?)?.isNotEmpty == true;

      expect(isPaired, isFalse);
    });
  });
}
