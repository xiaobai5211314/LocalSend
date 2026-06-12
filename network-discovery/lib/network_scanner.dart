import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:network_info_plus/network_info_plus.dart';

/// Result of scanning an IP address.
class ScanResult {
  final String ipAddress;
  final int port;
  final String? deviceId;
  final String? deviceName;
  final Duration responseTime;

  ScanResult({
    required this.ipAddress,
    required this.port,
    this.deviceId,
    this.deviceName,
    required this.responseTime,
  });

  @override
  bool operator ==(Object other) =>
      other is ScanResult && other.ipAddress == ipAddress && other.port == port;

  @override
  int get hashCode => Object.hash(ipAddress, port);
}

/// Represents a discovered network interface with subnet.
class NetworkInterface_ {
  final String name;
  final String ipAddress;
  final String subnetMask;
  final List<String> addresses;

  NetworkInterface_({
    required this.name,
    required this.ipAddress,
    required this.subnetMask,
    required this.addresses,
  });

  /// Generate all host IPs in this interface's subnet (excluding network and broadcast).
  List<String> generateSubnetIps() {
    final ips = <String>[];
    final ipParts = ipAddress.split('.').map(int.parse).toList();
    final maskParts = subnetMask.split('.').map(int.parse).toList();

    // Calculate network range
    final networkInt = _ipToInt(ipParts) & _ipToInt(maskParts);
    final broadcastInt = networkInt | (~_ipToInt(maskParts) & 0xFFFFFFFF);

    for (int ip = networkInt + 1; ip < broadcastInt; ip++) {
      ips.add('${(ip >> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}');
    }
    return ips;
  }
}

/// Network scanner for discovering LocalSend devices across all
/// network interfaces.
///
/// Scans each subnet for devices listening on the LocalSend
/// discovery port (53317). Results are deduplicated by device_id.
/// Implements a cache with 30-second TTL to avoid redundant scans.
class NetworkScanner {
  final NetworkInfo _networkInfo = NetworkInfo();

  /// Cache: subnet -> (results, timestamp)
  final Map<String, _CacheEntry> _cache = {};
  static const Duration _cacheTtl = Duration(seconds: 30);

  /// Default discovery port used by LocalSend.
  static const int discoveryPort = 53317;

  /// Maximum number of parallel scan connections.
  static const int maxConcurrency = 50;

  /// Connection timeout per IP.
  static const Duration perIpTimeout = Duration(milliseconds: 300);

  /// Callback invoked when scan progress updates.
  void Function(int completed, int total)? onProgress;

  /// Callback invoked when a device is found.
  void Function(ScanResult result)? onDeviceFound;

  /// Whether a scan is currently in progress.
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  // ============================================================
  // Interface Discovery
  // ============================================================

  /// Get all network interfaces with their IP info.
  Future<List<NetworkInterface_>> getInterfaces() async {
    final interfaces = <NetworkInterface_>[];
    final rawInterfaces = await NetworkInterface.list(
        includeLoopback: false, type: InternetAddressType.IPv4);

    for (final iface in rawInterfaces) {
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;

        final subnetMask = _cidrToSubnetMask(addr);

        interfaces.add(NetworkInterface_(
          name: iface.name,
          ipAddress: addr.address,
          subnetMask: subnetMask,
          addresses: iface.addresses.map((a) => a.address).toList(),
        ));
      }
    }

    return interfaces;
  }

  String _cidrToSubnetMask(InternetAddress addr) {
    if (addr is InternetAddress && addr.type == InternetAddressType.IPv4) {
      final parts = addr.address.split('.');
      if (parts[0] == '10') return '255.0.0.0';
      if (parts[0] == '172' &&
          int.parse(parts[1]) >= 16 &&
          int.parse(parts[1]) <= 31) {
        return '255.255.0.0';
      }
      if (parts[0] == '192' && parts[1] == '168') return '255.255.255.0';
    }
    // Default: /24 (255.255.255.0)
    return '255.255.255.0';
  }

  // ============================================================
  // Scanning
  // ============================================================

  /// Scan all network interfaces for LocalSend devices.
  ///
  /// Returns deduplicated results sorted by response time.
  Future<List<ScanResult>> scanAll() async {
    if (_isScanning) {
      throw StateError('A scan is already in progress');
    }
    _isScanning = true;

    try {
      final interfaces = await getInterfaces();
      final allResults = <ScanResult>[];

      for (final iface in interfaces) {
        // Check cache
        final cacheKey = '${iface.ipAddress}/${iface.subnetMask}';
        final cached = _cache[cacheKey];
        if (cached != null &&
            DateTime.now().difference(cached.timestamp) < _cacheTtl) {
          allResults.addAll(cached.results);
          continue;
        }

        final results = await scanInterface(iface);
        _cache[cacheKey] =
            _CacheEntry(List.from(results), DateTime.now());
        allResults.addAll(results);
      }

      // Deduplicate by device_id
      return _deduplicate(allResults);
    } finally {
      _isScanning = false;
    }
  }

  /// Scan a specific network interface.
  Future<List<ScanResult>> scanInterface(
      NetworkInterface_ iface) async {
    final subnetIps = iface.generateSubnetIps();
    final results = <ScanResult>[];
    int completed = 0;

    onProgress?.call(0, subnetIps.length);

    // Scan in batches to limit concurrency
    for (int i = 0; i < subnetIps.length; i += maxConcurrency) {
      final batch = subnetIps.skip(i).take(maxConcurrency).toList();
      final batchResults = await Future.wait(
        batch.map((ip) => _scanIp(ip)),
      );

      for (final result in batchResults) {
        if (result != null) {
          results.add(result);
          onDeviceFound?.call(result);
        }
        completed++;
        onProgress?.call(completed, subnetIps.length);
      }
    }

    return results;
  }

  /// Scan a manual IP range.
  ///
  /// [startIp] and [endIp] are strings like "192.168.1.100".
  Future<List<ScanResult>> scanRange(
      String startIp, String endIp) async {
    if (_isScanning) {
      throw StateError('A scan is already in progress');
    }
    _isScanning = true;

    try {
      final startInt = _ipToInt(startIp.split('.').map(int.parse).toList());
      final endInt = _ipToInt(endIp.split('.').map(int.parse).toList());

      final ips = <String>[];
      for (int ip = startInt; ip <= endInt; ip++) {
        ips.add(
            '${(ip >> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}');
      }

      final results = <ScanResult>[];
      int completed = 0;

      onProgress?.call(0, ips.length);

      for (int i = 0; i < ips.length; i += maxConcurrency) {
        final batch = ips.skip(i).take(maxConcurrency).toList();
        final batchResults = await Future.wait(
          batch.map((ip) => _scanIp(ip)),
        );

        for (final result in batchResults) {
          if (result != null) {
            results.add(result);
            onDeviceFound?.call(result);
          }
          completed++;
          onProgress?.call(completed, ips.length);
        }
      }

      return _deduplicate(results);
    } finally {
      _isScanning = false;
    }
  }

  /// Scan a specific IP address.
  Future<ScanResult?> _scanIp(String ip) async {
    try {
      final stopwatch = Stopwatch()..start();

      final socket = await Socket.connect(
        ip,
        discoveryPort,
        timeout: perIpTimeout,
      );

      stopwatch.stop();

      // Read device info from connection
      String? deviceId;
      String? deviceName;

      try {
        socket.listen(
          (data) {
            final text = String.fromCharCodes(data);
            // Parse LocalSend discovery response
            final lines = text.split('\n');
            for (final line in lines) {
              if (line.startsWith('device_id:')) {
                deviceId = line.substring(10).trim();
              } else if (line.startsWith('device_name:')) {
                deviceName = line.substring(12).trim();
              }
            }
          },
          onError: (_) {},
          onDone: () {},
          cancelOnError: true,
        );

        // Give it a short time to receive data
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (_) {
        // Device may not respond with details, which is ok
      }

      await socket.close();

      return ScanResult(
        ipAddress: ip,
        port: discoveryPort,
        deviceId: deviceId,
        deviceName: deviceName,
        responseTime: stopwatch.elapsed,
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // Cache Management
  // ============================================================

  /// Clear the scan cache (force fresh scan on next request).
  void clearCache() {
    _cache.clear();
  }

  /// Get cached results for a specific subnet.
  List<ScanResult>? getCached(String subnet) {
    final entry = _cache[subnet];
    if (entry != null &&
        DateTime.now().difference(entry.timestamp) < _cacheTtl) {
      return entry.results;
    }
    return null;
  }

  // ============================================================
  // Helpers
  // ============================================================

  List<ScanResult> _deduplicate(List<ScanResult> results) {
    final seen = <String>{};
    return results.where((result) {
      // Deduplicate by device_id if available, otherwise by IP
      final key = result.deviceId ?? result.ipAddress;
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList()
      ..sort((a, b) => a.responseTime.compareTo(b.responseTime));
  }

  static int _ipToInt(List<int> parts) {
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }
}

/// Internal cache entry for scan results.
class _CacheEntry {
  final List<ScanResult> results;
  final DateTime timestamp;

  _CacheEntry(this.results, this.timestamp);
}
