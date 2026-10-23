import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_discovery.dart';

class ProcessingClient {
  final http.Client _client;
  final String? explicitUrl;
  String? _cachedBaseUrl;

  ProcessingClient({http.Client? client, this.explicitUrl})
      : _client = client ?? http.Client();

  Future<String> _getBaseUrl() async {
    final explicit = explicitUrl;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit.replaceAll(RegExp(r'/+$'), '');
    }
    if (_cachedBaseUrl != null && _cachedBaseUrl!.isNotEmpty) {
      return _cachedBaseUrl!;
    }
    _cachedBaseUrl = await ServerDiscovery.instance.discoverServerUrl();
    return _cachedBaseUrl!;
  }

  Future<String> getBaseUrl() => _getBaseUrl();

  String _today() {
    final today = DateTime.now();
    return '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
  }

  Future<Map<String, dynamic>> fetchDailyReport(String patientId, {String? date}) async {
    final baseUrl = await _getBaseUrl();
    final targetDate = date ?? _today();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/daily-report',
    ).replace(queryParameters: {'date': targetDate});
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Daily report failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<String>> fetchHistoryDates(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/history-dates',
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('History dates failed (${response.statusCode}): ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['dates'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
  }

  Future<Map<String, dynamic>> fetchPeriodSummary(
    String patientId, {
    String window = 'weekly',
    String? date,
  }) async {
    final baseUrl = await _getBaseUrl();
    final params = <String, String>{'window': window};
    if (date != null) params['date'] = date;
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/summary',
    ).replace(queryParameters: params);
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Period summary failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchNotes(
    String patientId, {
    String? date,
  }) async {
    final baseUrl = await _getBaseUrl();
    final params = <String, String>{};
    if (date != null) params['date'] = date;
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/notes',
    ).replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Notes failed (${response.statusCode}): ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['notes'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];
  }

  Future<Map<String, dynamic>> addNote(
    String patientId, {
    required String date,
    required String text,
    List<String> tags = const [],
    String author = 'Caretaker',
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/notes',
    );
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'date': date,
        'text': text,
        'tags': tags,
        'author': author,
      }),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Add note failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> deleteNote(String patientId, String noteId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/notes/${Uri.encodeComponent(noteId)}',
    );
    final response = await _client.delete(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Delete note failed (${response.statusCode}): ${response.body}');
    }
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

  Future<void> deletePatient(String patientId) async {
    try {
      final baseUrl = await _getBaseUrl();
      final uri = Uri.parse('$baseUrl/patients/${Uri.encodeComponent(patientId)}');
      await _client.delete(uri).timeout(const Duration(seconds: 15));
    } catch (_) {
      // Best-effort backend deletion in case device is offline
    }
  }

  Future<Map<String, dynamic>> loadTestBaseline(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse('$baseUrl/patients/${Uri.encodeComponent(patientId)}/load-test-baseline');
    final response = await _client.post(uri).timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      throw StateError('Loading test baseline failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> fetchBaselineStatus(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/baseline',
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Baseline status failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> finalizeBaseline(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/baseline/finalize',
    );
    final response = await _client.post(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('Finalizing baseline failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> resetBaseline(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/baseline/reset',
    );
    final response = await _client.post(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Resetting baseline failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchAlerts(
    String patientId, {
    int afterTimestampMs = 0,
    String? status,
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/alerts',
    ).replace(queryParameters: {
      'after_timestamp_ms': '$afterTimestampMs',
      'limit': '100',
      'status': ?status,
    });
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Alerts failed (${response.statusCode}): ${response.body}');
    }
    return (jsonDecode(response.body) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> acknowledgeAlert(
    String patientId,
    String alertId,
  ) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/alerts/'
      '${Uri.encodeComponent(alertId)}/ack',
    );
    final response = await _client.post(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Acknowledging alert failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> dismissAlert(
    String patientId,
    String alertId, {
    String reason = 'false_positive',
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/alerts/'
      '${Uri.encodeComponent(alertId)}/dismiss',
    );
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'reason': reason}),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Dismissing alert failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> generatePairingCode(
    String patientId, {
    String patientName = '',
    int ttlSeconds = 900,
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/pairing/generate',
    );
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'patient_name': patientName,
        'ttl_seconds': ttlSeconds,
      }),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Generating pairing code failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getActivePairingCode(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/pairing/active',
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Fetching active pairing code failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> claimPairingCode(
    String code, {
    String caretakerName = '',
  }) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse('$baseUrl/pairing/claim');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'caretaker_name': caretakerName,
      }),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) {
      throw StateError('Invalid or expired pairing code');
    }
    if (response.statusCode != 200) {
      throw StateError('Claiming pairing code failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> unpairCaretaker(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/caretaker/unpair',
    );
    final response = await _client.post(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Unpairing caretaker failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateCaretakerProfile(
    String patientId,
    String caretakerName,
  ) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/caretaker/profile',
    );
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'caretaker_name': caretakerName}),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Updating caretaker profile failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getCaretaker(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/caretaker',
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw StateError('Fetching caretaker failed (${response.statusCode}): ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['caretaker'] as Map<String, dynamic>?;
  }

  Future<Map<String, dynamic>> getActiveStatus(String patientId) async {
    final baseUrl = await _getBaseUrl();
    final uri = Uri.parse(
      '$baseUrl/patients/${Uri.encodeComponent(patientId)}/active-status',
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Fetching active status failed (${response.statusCode}): ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
