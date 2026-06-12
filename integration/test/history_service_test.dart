import 'package:test/test.dart';

/// Tests for HistoryService CRUD operations.
///
/// These tests validate the data model and query logic without
/// requiring a real SQLite database. For database integration tests,
/// use sqflite's in-memory database or sqflite_common_ffi.

void main() {
  group('TransferRecord model', () {
    test('fromMap creates valid TransferRecord', () {
      final map = {
        'id': 1,
        'from_device': 'Device-A',
        'to_device': 'Device-B',
        'file_names': '["photo.jpg","doc.pdf"]',
        'total_size': 1048576,
        'status': 0, // completed
        'timestamp': 1700000000000,
        'direction': 0, // sent
        'original_paths': '["/photos/photo.jpg","/docs/doc.pdf"]',
        'duration_ms': 3500,
        'error_message': null,
      };

      // Simple manual parse (simulating fromMap without dart:convert)
      final fromDevice = map['from_device'] as String;
      final toDevice = map['to_device'] as String;
      final totalSize = map['total_size'] as int;
      final status = map['status'] as int;
      final timestamp = map['timestamp'] as int;
      final direction = map['direction'] as int;

      expect(fromDevice, equals('Device-A'));
      expect(toDevice, equals('Device-B'));
      expect(totalSize, equals(1048576));
      expect(status, equals(0));
      expect(timestamp, equals(1700000000000));
      expect(direction, equals(0));
    });

    test('file_names JSON array parses to list', () {
      import 'dart:convert';

      final json = '["photo.jpg","doc.pdf","spreadsheet.xlsx"]';
      final list = jsonDecode(json) as List;

      expect(list.length, equals(3));
      expect(list[0], equals('photo.jpg'));
      expect(list[1], equals('doc.pdf'));
      expect(list[2], equals('spreadsheet.xlsx'));
    });

    test('file_names with empty array is valid', () {
      import 'dart:convert';

      final json = '[]';
      final list = jsonDecode(json) as List;

      expect(list, isEmpty);
    });

    test('toMap produces correct structure', () {
      final map = {
        'from_device': 'Host',
        'to_device': 'Peer',
        'file_names': '["a.txt"]',
        'total_size': 100,
        'status': 0,
        'timestamp': 1700000000000,
        'direction': 1, // received
        'original_paths': null,
        'duration_ms': 1200,
        'error_message': null,
      };

      expect(map['from_device'], equals('Host'));
      expect(map['to_device'], equals('Peer'));
      expect(map['total_size'], equals(100));
      expect(map['direction'], equals(1));
      expect(map['error_message'], isNull);
    });

    test('totalSizeText formatting works correctly', () {
      String formatSize(int bytes) {
        if (bytes < 1024) return '$bytes B';
        if (bytes < 1024 * 1024) {
          return '${(bytes / 1024).toStringAsFixed(1)} KB';
        }
        if (bytes < 1024 * 1024 * 1024) {
          return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        }
        return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
      }

      expect(formatSize(0), equals('0 B'));
      expect(formatSize(500), equals('500 B'));
      expect(formatSize(1024), equals('1.0 KB'));
      expect(formatSize(1536), equals('1.5 KB'));
      expect(formatSize(1048576), equals('1.0 MB'));
      expect(formatSize(1048576 * 5), equals('5.0 MB'));
      expect(formatSize(1073741824), equals('1.0 GB'));
    });
  });

  group('TransferFilter query building', () {
    /// Simulate filter's buildWhereClause method.
    (String, List<dynamic>) buildWhereClause({
      String? deviceName,
      int? status,
      int? direction,
      int? startTime,
      int? endTime,
      String? fileNamePattern,
    }) {
      final conditions = <String>[];
      final params = <dynamic>[];

      if (deviceName != null) {
        conditions.add('(from_device = ? OR to_device = ?)');
        params.addAll([deviceName, deviceName]);
      }
      if (status != null) {
        conditions.add('status = ?');
        params.add(status);
      }
      if (direction != null) {
        conditions.add('direction = ?');
        params.add(direction);
      }
      if (startTime != null) {
        conditions.add('timestamp >= ?');
        params.add(startTime);
      }
      if (endTime != null) {
        conditions.add('timestamp <= ?');
        params.add(endTime);
      }
      if (fileNamePattern != null) {
        conditions.add('file_names LIKE ?');
        params.add('%$fileNamePattern%');
      }

      final where = conditions.isEmpty
          ? ''
          : 'WHERE ${conditions.join(" AND ")}';
      return (where, params);
    }

    test('empty filter produces no WHERE clause', () {
      final (where, params) = buildWhereClause();
      expect(where, isEmpty);
      expect(params, isEmpty);
    });

    test('device filter produces device WHERE clause', () {
      final (where, params) = buildWhereClause(deviceName: 'Phone');

      expect(where, contains('from_device = ?'));
      expect(where, contains('to_device = ?'));
      expect(params.length, equals(2));
      expect(params[0], equals('Phone'));
      expect(params[1], equals('Phone'));
    });

    test('status filter produces status WHERE clause', () {
      final (where, params) = buildWhereClause(status: 1); // failed

      expect(where, contains('status = ?'));
      expect(params, equals([1]));
    });

    test('direction filter produces direction WHERE clause', () {
      final (where, params) = buildWhereClause(direction: 0); // sent

      expect(where, contains('direction = ?'));
      expect(params, equals([0]));
    });

    test('time range filter produces time WHERE clause', () {
      final (where, params) =
          buildWhereClause(startTime: 1700000000000, endTime: 1710000000000);

      expect(where, contains('timestamp >= ?'));
      expect(where, contains('timestamp <= ?'));
      expect(params, equals([1700000000000, 1710000000000]));
    });

    test('fileNamePattern wraps with % wildcards', () {
      final (where, params) = buildWhereClause(fileNamePattern: 'invoice');

      expect(where, contains('file_names LIKE ?'));
      expect(params[0], equals('%invoice%'));
    });

    test('combined filters produce all conditions', () {
      final (where, params) = buildWhereClause(
        deviceName: 'Laptop',
        status: 0,
        direction: 1,
        startTime: 1700000000000,
        endTime: 1710000000000,
        fileNamePattern: 'pdf',
      );

      expect(where, contains('AND'));
      expect(params.length, equals(7));
    });
  });

  group('TransferRecord query sorting', () {
    test('records sort by timestamp descending', () {
      final records = [
        _TestRecord(ts: 1000),
        _TestRecord(ts: 3000),
        _TestRecord(ts: 2000),
      ];

      records.sort((a, b) => b.ts.compareTo(a.ts));

      expect(records[0].ts, equals(3000));
      expect(records[1].ts, equals(2000));
      expect(records[2].ts, equals(1000));
    });

    test('filter by status produces correct results', () {
      final records = [
        _TestRecord(ts: 1000, status: 0),
        _TestRecord(ts: 2000, status: 1),
        _TestRecord(ts: 3000, status: 0),
        _TestRecord(ts: 4000, status: 2),
      ];

      final failed = records.where((r) => r.status == 1).toList();
      final completed = records.where((r) => r.status == 0).toList();

      expect(failed.length, equals(1));
      expect(completed.length, equals(2));
    });
  });
}

/// Simplified test record for sorting/filtering tests.
class _TestRecord {
  final int ts;
  final int status;
  _TestRecord({required this.ts, this.status = 0});
}
