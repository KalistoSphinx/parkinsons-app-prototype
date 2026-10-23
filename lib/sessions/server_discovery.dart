import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../database/local_database.dart';

class ServerDiscovery {
  static final ServerDiscovery instance = ServerDiscovery._();
  ServerDiscovery._();

  String? _cachedUrl;

  String? get cachedUrl => _cachedUrl;

  void invalidateCachedUrl() {
    _cachedUrl = null;
  }

  Future<bool> checkHealth(
    String baseUrl, {
    Duration timeout = const Duration(milliseconds: 1000),
  }) async {
    try {
      final sanitized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$sanitized/health');
      final response = await http.get(uri).timeout(timeout);
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return body is Map && body['status'] == 'ok';
      }
    } catch (_) {}
    return false;
  }

  Future<void> setManualUrl(String url) async {
    final sanitized = url.trim().replaceAll(RegExp(r'/+$'), '');
    _cachedUrl = sanitized;
    await LocalDatabase.instance.saveServerUrl(sanitized);
  }

  Future<String> discoverServerUrl({bool forceScan = false}) async {
    if (!forceScan && _cachedUrl != null && _cachedUrl!.isNotEmpty) {
      return _cachedUrl!;
    }

    // 1. Check database/cache
    final dbUrl = await LocalDatabase.instance.getServerUrl();
    if (!forceScan && dbUrl != null && dbUrl.isNotEmpty) {
      if (await checkHealth(dbUrl)) {
        _cachedUrl = dbUrl;
        return dbUrl;
      }
    }

    // 2. Check dart-define if provided and not default 10.0.2.2
    const envUrl = String.fromEnvironment('PROCESSING_URL');
    if (envUrl.isNotEmpty && envUrl != 'http://10.0.2.2:8000') {
      final sanitized = envUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (await checkHealth(sanitized)) {
        _cachedUrl = sanitized;
        await LocalDatabase.instance.saveServerUrl(sanitized);
        return sanitized;
      }
    }

    // 3. Scan local Wi-Fi subnet(s)
    try {
      final ownIps = await _getOwnIps();
      final subnets = await _getLocalSubnets();
      for (final subnet in subnets) {
        final found = await _scanSubnetForServer(subnet, ownIps);
        if (found != null) {
          final url = 'http://$found:8000';
          _cachedUrl = url;
          await LocalDatabase.instance.saveServerUrl(url);
          return url;
        }
      }
    } catch (_) {}

    // 4. Check loopbacks / emulator addresses
    const loopbacks = [
      'http://127.0.0.1:8000',
      'http://10.0.2.2:8000',
    ];
    for (final url in loopbacks) {
      if (await checkHealth(url, timeout: const Duration(milliseconds: 600))) {
        _cachedUrl = url;
        await LocalDatabase.instance.saveServerUrl(url);
        return url;
      }
    }

    // Fallback: return cached or default emulator URL
    final fallback = dbUrl ?? (envUrl.isNotEmpty ? envUrl : 'http://10.0.2.2:8000');
    _cachedUrl = fallback;
    return fallback;
  }

  Future<Set<String>> _getOwnIps() async {
    final ips = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          ips.add(addr.address);
        }
      }
    } catch (_) {}
    return ips;
  }

  Future<List<String>> _getLocalSubnets() async {
    final subnets = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (_) {}
    return subnets.toList();
  }

  Future<String?> _scanSubnetForServer(String subnet, Set<String> excludeIps) async {
    final completer = Completer<String?>();
    int pending = 254;

    for (int i = 1; i <= 254; i++) {
      final host = '$subnet.$i';
      if (excludeIps.contains(host)) {
        pending--;
        continue;
      }

      () async {
        try {
          final socket = await Socket.connect(
            host,
            8000,
            timeout: const Duration(milliseconds: 800),
          );
          socket.destroy();

          if (await checkHealth('http://$host:8000', timeout: const Duration(milliseconds: 1000))) {
            if (!completer.isCompleted) {
              completer.complete(host);
            }
          }
        } catch (_) {} finally {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }();
    }

    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  }
}
