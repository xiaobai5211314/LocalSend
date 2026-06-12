import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

/// Result of hotspot detection.
class HotspotDetectionResult {
  /// Whether this device is currently acting as a hotspot.
  final bool isHotspot;

  /// Whether we are connected to a hotspot network.
  final bool isConnectedToHotspot;

  /// Detected hotspot gateway IP.
  final String? gatewayIp;

  /// Subnet of the hotspot network (e.g., "192.168.43.0/24").
  final String? subnet;

  /// Name of the network interface (may contain "hotspot"/"tether" keywords).
  final String? interfaceName;

  /// Whether the scanner should use full-subnet scan mode.
  final bool fullSubnetScanRecommended;

  HotspotDetectionResult({
    required this.isHotspot,
    required this.isConnectedToHotspot,
    this.gatewayIp,
    this.subnet,
    this.interfaceName,
    this.fullSubnetScanRecommended = false,
  });

  @override
  String toString() =>
      'HotspotDetectionResult(isHotspot=$isHotspot, '
      'isConnectedToHotspot=$isConnectedToHotspot, gateway=$gatewayIp, '
      'interface=$interfaceName, fullScan=$fullSubnetScanRecommended)';
}

/// Detects whether the device is providing or connected to a
/// mobile hotspot network.
///
/// Uses multiple heuristics:
/// 1. Gateway IP matching known hotspot defaults
/// 2. Subnet pattern matching (common /24 hotspot subnets)
/// 3. Network interface name keyword matching
///
/// When a hotspot is detected, the scanner should enable full
/// subnet scanning to ensure maximum device discovery.
class HotspotDetector {
  final NetworkInfo _networkInfo = NetworkInfo();

  /// Known Android hotspot gateway IPs.
  static const Set<String> androidHotspotGateways = {
    '192.168.43.1',
    '192.168.42.129',
    '192.168.43.9',
    '192.168.43.254',
  };

  /// Known iOS hotspot gateway IPs.
  static const Set<String> iosHotspotGateways = {
    '172.20.10.1',
  };

  /// Known Windows/Linux hotspot gateway IPs.
  static const Set<String> desktopHotspotGateways = {
    '192.168.137.1',
  };

  /// All known hotspot gateway IPs.
  static Set<String> get allHotspotGateways => {
        ...androidHotspotGateways,
        ...iosHotspotGateways,
        ...desktopHotspotGateways,
      };

  /// Subnet patterns commonly used by hotspots.
  static const List<String> hotspotSubnetPatterns = [
    '192.168.43.',
    '192.168.42.',
    '172.20.10.',
    '192.168.137.',
  ];

  /// Interface name keywords indicating hotspot mode.
  static const List<String> hotspotInterfaceKeywords = [
    'hotspot',
    'tether',
    'Hotspot',
    'Tether',
    '热点',
    'wlan0',
    'ap0',
    'SoftAP',
    'Microsoft Wi-Fi Direct Virtual Adapter',
  ];

  /// Cached detection result (short-lived).
  HotspotDetectionResult? _cachedResult;
  DateTime? _cacheTime;
  static const Duration _cacheTtl = Duration(seconds: 10);

  /// Detect whether the current network is a hotspot.
  ///
  /// Uses a short-lived cache to avoid repeated system calls.
  Future<HotspotDetectionResult> detect() async {
    // Return cached result if still fresh
    if (_cachedResult != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheTtl) {
      return _cachedResult!;
    }

    final result = await _performDetection();
    _cachedResult = result;
    _cacheTime = DateTime.now();
    return result;
  }

  Future<HotspotDetectionResult> _performDetection() async {
    try {
      final gatewayIp = await _networkInfo.getWifiGatewayIP();
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);

      bool isHotspotNetwork = false;
      bool isProvidingHotspot = false;
      String? matchedInterfaceName;
      String? subnet;

      // Check: gateway IP matches known hotspot defaults
      if (gatewayIp != null && allHotspotGateways.contains(gatewayIp)) {
        isHotspotNetwork = true;
      }

      // Check: interface name contains hotspot keywords
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;

          for (final keyword in hotspotInterfaceKeywords) {
            if (iface.name.toLowerCase().contains(keyword.toLowerCase())) {
              matchedInterfaceName = iface.name;
              isHotspotNetwork = true;

              // Check if we are the hotspot provider
              if (addr.address == gatewayIp) {
                isProvidingHotspot = true;
              }
              break;
            }
          }

          if (matchedInterfaceName != null) break;

          // Check subnet pattern
          for (final pattern in hotspotSubnetPatterns) {
            if (addr.address.startsWith(pattern)) {
              subnet = '${pattern}0/24';
              isHotspotNetwork = true;
              break;
            }
          }

          if (matchedInterfaceName != null || isHotspotNetwork) break;
        }
        if (matchedInterfaceName != null || isHotspotNetwork) break;
      }

      // If no hotspot detected, check the interface names for hotspot mode
      // (the device itself may be providing the hotspot)
      if (!isHotspotNetwork && !isProvidingHotspot) {
        for (final iface in interfaces) {
          for (final keyword in hotspotInterfaceKeywords) {
            if (iface.name.toLowerCase().contains(keyword.toLowerCase())) {
              matchedInterfaceName = iface.name;
              isProvidingHotspot = true;
              break;
            }
          }
          if (isProvidingHotspot) break;
        }
      }

      // Full subnet scan is recommended for hotspots because:
      // - DHCP lease ranges vary between hotspot implementations
      // - Devices may appear at unpredictable IPs
      final needsFullScan = isHotspotNetwork || isProvidingHotspot;

      return HotspotDetectionResult(
        isHotspot: isProvidingHotspot,
        isConnectedToHotspot: isHotspotNetwork,
        gatewayIp: gatewayIp,
        subnet: subnet,
        interfaceName: matchedInterfaceName,
        fullSubnetScanRecommended: needsFullScan,
      );
    } catch (_) {
      return HotspotDetectionResult(
        isHotspot: false,
        isConnectedToHotspot: false,
        fullSubnetScanRecommended: false,
      );
    }
  }

  /// Quick check: is this a hotspot environment?
  ///
  /// Faster than [detect] but less accurate — only checks gateway IP.
  Future<bool> isLikelyHotspot() async {
    try {
      final gatewayIp = await _networkInfo.getWifiGatewayIP();
      return gatewayIp != null && allHotspotGateways.contains(gatewayIp);
    } catch (_) {
      return false;
    }
  }

  /// Clear cached detection result.
  void clearCache() {
    _cachedResult = null;
    _cacheTime = null;
  }

  /// Get recommended scan parameters for the current network.
  ///
  /// In hotspot mode, returns parameters for a full /24 scan.
  /// Otherwise, returns standard scan parameters.
  Future<HotspotScannerParams> getScannerParams() async {
    final detection = await detect();

    if (detection.fullSubnetScanRecommended) {
      // Determine which subnet to scan
      String baseSubnet;
      if (detection.gatewayIp != null) {
        // Scan the gateway's /24 subnet
        final parts = detection.gatewayIp!.split('.');
        baseSubnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      } else {
        baseSubnet = '192.168.43'; // Default Android hotspot
      }

      return HotspotScannerParams(
        scanMode: ScanMode.fullSubnet,
        subnet: '$baseSubnet.0/24',
        port: 53317,
        maxConcurrency: 100,
      );
    }

    return HotspotScannerParams(
      scanMode: ScanMode.auto,
      port: 53317,
      maxConcurrency: 50,
    );
  }
}

/// Scan mode based on network environment.
enum ScanMode {
  /// Standard subnet scan (default).
  auto,

  /// Full /24 subnet scan for hotspot networks.
  fullSubnet,

  /// Custom IP range scan.
  custom,
}

/// Parameters for the network scanner, adjusted based on hotspot detection.
class HotspotScannerParams {
  final ScanMode scanMode;
  final String? subnet;
  final int port;
  final int maxConcurrency;

  HotspotScannerParams({
    required this.scanMode,
    this.subnet,
    required this.port,
    required this.maxConcurrency,
  });

  @override
  String toString() =>
      'HotspotScannerParams(mode=$scanMode, subnet=$subnet, '
      'port=$port, concurrency=$maxConcurrency)';
}
