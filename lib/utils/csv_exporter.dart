import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import '../database/local_database.dart';

class CsvExporter {
  static Future<File?> exportMeasurements(LocalDatabase db, String patientId) async {
    try {
      final measurements = await db.getMeasurements(patientId);
      
      List<List<dynamic>> rows = [
        ['patientId', 'sessionId', 'timestamp', 'featureName', 'value']
      ];

      for (var m in measurements) {
        rows.add([
          m.patientId,
          m.sessionId,
          m.timestamp.toIso8601String(),
          m.featureName,
          m.value,
        ]);
      }

      String csv = Csv().encode(rows);
      
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/measurements_${patientId}_${DateTime.now().millisecondsSinceEpoch}.csv');
      
      await file.writeAsString(csv);
      return file;
    } catch (e) {
      print('Export error: $e');
      return null;
    }
  }
}
