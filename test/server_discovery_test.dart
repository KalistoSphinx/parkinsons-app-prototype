import 'package:flutter_test/flutter_test.dart';
import 'package:prototype/sessions/continuous_monitor_controller.dart';
import 'package:prototype/sessions/server_discovery.dart';

void main() {
  test('wrist position is always left', () {
    final controller = ContinuousMonitorController();
    expect(ContinuousMonitorController.fixedWatchSide, 'left');
    expect(controller.watchSide, 'left');
  });

  test('ServerDiscovery checkHealth identifies live endpoint or rejects invalid', () async {
    final discovery = ServerDiscovery.instance;
    // An invalid URL or dead port should return false without throwing an exception
    final healthy = await discovery.checkHealth('http://192.0.2.1:8999', timeout: const Duration(milliseconds: 200));
    expect(healthy, isFalse);
  });
}
