import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_discovery.dart';

class ProcessingClient {
  final http.Client _client;
  final String? explicitUrl;

  ProcessingClient({http.Client? client, this.explicitUrl})
      : _client = client ?? http.Client();

  Future<String> _getBaseUrl() async {
    final explicit = explicitUrl;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit.replaceAll(RegExp(r'/+$'), '');
    }
    return await ServerDiscovery.instance.discoverServerUrl();
  }

  String _today() {
    final today = DateTime.now();
    return '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
  }

  Future<Map<String, dynamic>> fetchDailyReport(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/daily-report',
    ).replace(queryParameters: {'date': _today()});
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Daily report failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchFeatureVectors(
    String patientId, {
    required int afterTimestampMs,
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/feature-vectors',
    ).replace(queryParameters: {
      'after_timestamp_ms': '$afterTimestampMs',
      'limit': '500',
    });
    final response = await _client.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('Feature history failed (${response.statusCode}): ${response.body}');
    }
    return (jsonDecode(response.body) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }
}
