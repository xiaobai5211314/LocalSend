import 'dart:io';
import 'dart:async';
import 'package:network_info_plus/network_info_plus.dart';

class NetworkDiscoveryService {
  final _devicesController = StreamController<List<Map<String, String>>>.broadcast();
  Stream<List<Map<String, String>>> get discoveredDevices => _devicesController.stream;

  Future<List<String>> scanLocalSubnet({int port = 9000, int timeoutMs = 200}) async {
    final results = <String>[];
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    if (ip == null) return results;

    final parts = ip.split('.');
    if (parts.length != 4) return results;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    final futures = <Future>[];
    for (var i = 1; i <= 254; i++) {
      futures.add(_tryConnect('$prefix.$i', port, timeoutMs).then((ok) {
        if (ok) results.add('$prefix.$i');
      }));
    }
    await Future.wait(futures);
    return results;
  }

  Future<bool> _tryConnect(String host, int port, int timeoutMs) async {
    try {
      final socket = await Socket.connect(
        host, port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isHotspotActive() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      if (ip == null || ip.startsWith('192.168.137')) {
        return true;
      }
      for (final interface in await NetworkInterface.list()) {
        for (final addr in interface.addresses) {
          if (addr.address.startsWith('192.168.137')) return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _devicesController.close();
  }
}
