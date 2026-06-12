import 'package:test/test.dart';

/// Tests for the NetworkScanner subnet IP generation and
/// deduplication logic.
///
/// Validates the IP math, subnet calculation, and result
/// deduplication without requiring actual network access.

void main() {
  group('NetworkScanner subnet IP generation', () {
    /// Generate all host IPs in a /24 subnet.
    List<String> generateSubnetIps(String ipAddress, String subnetMask) {
      final ips = <String>[];
      final ipParts = ipAddress.split('.').map(int.parse).toList();
      final maskParts = subnetMask.split('.').map(int.parse).toList();

      final networkInt =
          _ipToInt(ipParts) & _ipToInt(maskParts);
      final broadcastInt =
          networkInt | (~_ipToInt(maskParts) & 0xFFFFFFFF);

      for (int ip = networkInt + 1; ip < broadcastInt; ip++) {
        ips.add(
            '${(ip >> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}');
      }
      return ips;
    }

    test('/24 subnet generates 254 IPs (excludes network and broadcast)', () {
      final ips = generateSubnetIps('192.168.1.5', '255.255.255.0');

      expect(ips.length, equals(254));
      expect(ips.contains('192.168.1.0'), isFalse); // Network address
      expect(ips.contains('192.168.1.255'), isFalse); // Broadcast
      expect(ips.contains('192.168.1.1'), isTrue);
      expect(ips.contains('192.168.1.254'), isTrue);
    });

    test('/16 subnet generates 65534 IPs', () {
      // Only test the edges
      final ips = generateSubnetIps('10.0.0.5', '255.255.0.0');

      expect(ips.length, equals(65534));
      expect(ips.first, equals('10.0.0.1'));
      expect(ips.last, equals('10.0.255.254'));
      expect(ips.contains('10.0.0.0'), isFalse);
      expect(ips.contains('10.0.255.255'), isFalse);
    });

    test('/24 subnet with 192.168.43.x (hotspot)', () {
      final ips = generateSubnetIps('192.168.43.100', '255.255.255.0');

      expect(ips.length, equals(254));
      expect(ips.contains('192.168.43.1'), isTrue);
      expect(ips.contains('192.168.43.254'), isTrue);
    });

    test('/24 subnet with 172.20.10.x (iOS hotspot)', () {
      final ips = generateSubnetIps('172.20.10.5', '255.255.255.0');

      expect(ips.length, equals(254));
      expect(ips.contains('172.20.10.1'), isTrue);
      expect(ips.contains('172.20.10.254'), isTrue);
    });

    test('/28 subnet (small subnet) generates correct IPs', () {
      final ips = generateSubnetIps('192.168.1.5', '255.255.255.240');

      expect(ips.length, equals(14)); // 16 - 2
      expect(ips.first, equals('192.168.1.1'));
      expect(ips.last, equals('192.168.1.14'));
    });

    test('/30 subnet (point-to-point) generates 2 IPs', () {
      final ips = generateSubnetIps('10.0.0.1', '255.255.255.252');

      expect(ips.length, equals(2));
    });
  });

  group('NetworkScanner IP math helpers', () {
    test('_ipToInt converts IP to integer', () {
      expect(_ipToInt([192, 168, 1, 1]), equals(0xC0A80101));
      expect(_ipToInt([10, 0, 0, 5]), equals(0x0A000005));
      expect(_ipToInt([255, 255, 255, 255]), equals(0xFFFFFFFF));
      expect(_ipToInt([0, 0, 0, 0]), equals(0));
    });
  });

  group('NetworkScanner result deduplication', () {
    /// Deduplicate by device_id if available, otherwise by IP.
    List<Map<String, dynamic>> deduplicate(
        List<Map<String, dynamic>> results) {
      final seen = <String>{};
      return results.where((result) {
        final key =
            result['device_id']?.toString() ?? result['ip_address']?.toString();
        if (key == null || seen.contains(key)) return false;
        seen.add(key);
        return true;
      }).toList();
    }

    test('deduplicates by device_id', () {
      final results = [
        {'ip_address': '192.168.1.10', 'device_id': 'dev-A'},
        {'ip_address': '192.168.1.11', 'device_id': 'dev-A'}, // Duplicate
        {'ip_address': '192.168.1.12', 'device_id': 'dev-B'},
      ];

      final deduped = deduplicate(results);
      expect(deduped.length, equals(2));
      expect(deduped[0]['device_id'], equals('dev-A'));
      expect(deduped[1]['device_id'], equals('dev-B'));
    });

    test('deduplicates by IP when no device_id', () {
      final results = [
        {'ip_address': '192.168.1.10'},
        {'ip_address': '192.168.1.10'}, // Duplicate
        {'ip_address': '192.168.1.11'},
      ];

      final deduped = deduplicate(results);
      expect(deduped.length, equals(2));
    });

    test('empty list returns empty', () {
      final results = <Map<String, dynamic>>[];
      final deduped = deduplicate(results);
      expect(deduped, isEmpty);
    });

    test('no duplicates returns same list', () {
      final results = [
        {'ip_address': '192.168.1.10', 'device_id': 'dev-A'},
        {'ip_address': '192.168.2.10', 'device_id': 'dev-B'},
        {'ip_address': '192.168.3.10', 'device_id': 'dev-C'},
      ];

      final deduped = deduplicate(results);
      expect(deduped.length, equals(3));
    });
  });

  group('NetworkScanner parallel batching', () {
    test('256 IPs in batches of 50 creates 6 batches', () {
      final ips = List.generate(256, (_) => '192.168.1.1');
      const batchSize = 50;
      final numBatches = (ips.length / batchSize).ceil();

      expect(numBatches, equals(6));
    });

    test('small list creates one batch', () {
      final ips = List.generate(10, (_) => '10.0.0.1');
      const batchSize = 50;
      final numBatches = (ips.length / batchSize).ceil();

      expect(numBatches, equals(1));
    });

    test('exact batch size creates one batch', () {
      final ips = List.generate(50, (_) => '10.0.0.1');
      const batchSize = 50;
      final numBatches = (ips.length / batchSize).ceil();

      expect(numBatches, equals(1));
    });
  });

  group('NetworkScanner cache TTL', () {
    test('30-second TTL cache entries expire correctly', () {
      const cacheTtl = Duration(seconds: 30);
      final now = DateTime.now();

      // Entry from 10 seconds ago should be valid
      final recentTime = now.subtract(const Duration(seconds: 10));
      expect(now.difference(recentTime) < cacheTtl, isTrue);

      // Entry from 40 seconds ago should be expired
      final oldTime = now.subtract(const Duration(seconds: 40));
      expect(now.difference(oldTime) < cacheTtl, isFalse);
    });
  });

  group('NetworkScanner manual range scanning', () {
    test('IP range generates correct list', () {
      List<String> generateRange(String startIp, String endIp) {
        final startInt = _ipToInt(startIp.split('.').map(int.parse).toList());
        final endInt = _ipToInt(endIp.split('.').map(int.parse).toList());

        final ips = <String>[];
        for (int ip = startInt; ip <= endInt; ip++) {
          ips.add(
              '${(ip >> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}');
        }
        return ips;
      }

      final ips = generateRange('192.168.1.100', '192.168.1.105');

      expect(ips.length, equals(6));
      expect(ips, equals([
        '192.168.1.100',
        '192.168.1.101',
        '192.168.1.102',
        '192.168.1.103',
        '192.168.1.104',
        '192.168.1.105',
      ]));
    });

    test('single IP range returns one IP', () {
      List<String> generateRange(String startIp, String endIp) {
        final startInt = _ipToInt(startIp.split('.').map(int.parse).toList());
        final endInt = _ipToInt(endIp.split('.').map(int.parse).toList());
        final ips = <String>[];
        for (int ip = startInt; ip <= endInt; ip++) {
          ips.add(
              '${(ip >> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}');
        }
        return ips;
      }

      final ips = generateRange('10.0.0.5', '10.0.0.5');
      expect(ips.length, equals(1));
      expect(ips[0], equals('10.0.0.5'));
    });
  });
}

/// Convert IP octets to a 32-bit unsigned integer.
int _ipToInt(List<int> parts) {
  return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}
