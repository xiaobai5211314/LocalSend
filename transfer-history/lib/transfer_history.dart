import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// Transfer status enumeration.
enum TransferStatus {
  pending,
  inProgress,
  paused,
  completed,
  failed,
  cancelled,
}

/// Represents a single file transfer record.
class TransferRecord {
  final int? id;
  final String fromDevice;
  final String toDevice;
  final String fileName;
  final int fileSize;
  final TransferStatus status;
  final int timestamp;
  final String? filePath;
  final int? durationMs;
  final String? errorMessage;

  TransferRecord({
    this.id,
    required this.fromDevice,
    required this.toDevice,
    required this.fileName,
    required this.fileSize,
    required this.status,
    required this.timestamp,
    this.filePath,
    this.durationMs,
    this.errorMessage,
  });

  /// Create a TransferRecord from a database row map.
  factory TransferRecord.fromMap(Map<String, dynamic> map) {
    return TransferRecord(
      id: map['id'] as int?,
      fromDevice: map['from_device'] as String,
      toDevice: map['to_device'] as String,
      fileName: map['file_name'] as String,
      fileSize: map['file_size'] as int,
      status: TransferStatus.values[map['status'] as int],
      timestamp: map['timestamp'] as int,
      filePath: map['file_path'] as String?,
      durationMs: map['duration_ms'] as int?,
      errorMessage: map['error_message'] as String?,
    );
  }

  /// Convert to a map for database insertion.
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'from_device': fromDevice,
      'to_device': toDevice,
      'file_name': fileName,
      'file_size': fileSize,
      'status': status.index,
      'timestamp': timestamp,
      'file_path': filePath,
      'duration_ms': durationMs,
      'error_message': errorMessage,
    };
  }

  /// Human-readable status string.
  String get statusText {
    switch (status) {
      case TransferStatus.pending:
        return 'Pending';
      case TransferStatus.inProgress:
        return 'In Progress';
      case TransferStatus.paused:
        return 'Paused';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.failed:
        return 'Failed';
      case TransferStatus.cancelled:
        return 'Cancelled';
    }
  }

  /// Human-readable file size.
  String get fileSizeText {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  TransferRecord copyWith({
    int? id,
    String? fromDevice,
    String? toDevice,
    String? fileName,
    int? fileSize,
    TransferStatus? status,
    int? timestamp,
    String? filePath,
    int? durationMs,
    String? errorMessage,
  }) {
    return TransferRecord(
      id: id ?? this.id,
      fromDevice: fromDevice ?? this.fromDevice,
      toDevice: toDevice ?? this.toDevice,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      filePath: filePath ?? this.filePath,
      durationMs: durationMs ?? this.durationMs,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Filter criteria for querying transfer history.
class TransferFilter {
  final String? deviceName;
  final TransferStatus? status;
  final int? startTime;
  final int? endTime;
  final String? fileNamePattern;

  TransferFilter({
    this.deviceName,
    this.status,
    this.startTime,
    this.endTime,
    this.fileNamePattern,
  });

  /// Build SQL WHERE clause and parameters from filter.
  (String, List<dynamic>) buildWhereClause() {
    final conditions = <String>[];
    final params = <dynamic>[];

    if (deviceName != null) {
      conditions.add('(from_device = ? OR to_device = ?)');
      params.addAll([deviceName, deviceName]);
    }
    if (status != null) {
      conditions.add('status = ?');
      params.add(status!.index);
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
      conditions.add('file_name LIKE ?');
      params.add('%$fileNamePattern%');
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';
    return (where, params);
  }
}

/// Transfer history service backed by SQLite.
///
/// Provides CRUD operations for transfer records with filtering by
/// time range, device, status, and file name.
class TransferHistoryService {
  static TransferHistoryService? _instance;
  Database? _db;

  TransferHistoryService._();

  /// Get singleton instance.
  static TransferHistoryService get instance {
    _instance ??= TransferHistoryService._();
    return _instance!;
  }

  /// Initialize the database and create tables.
  Future<void> init(String dbPath) async {
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transfer_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_device TEXT NOT NULL,
        to_device TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        timestamp INTEGER NOT NULL,
        file_path TEXT,
        duration_ms INTEGER,
        error_message TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_transfer_timestamp ON transfer_records(timestamp)
    ''');

    await db.execute('''
      CREATE INDEX idx_transfer_status ON transfer_records(status)
    ''');

    await db.execute('''
      CREATE INDEX idx_transfer_device ON transfer_records(from_device, to_device)
    ''');
  }

  /// Insert a new transfer record.
  ///
  /// Returns the inserted record with its assigned ID.
  Future<TransferRecord> insert(TransferRecord record) async {
    final db = _requireDb();
    final id = await db.insert('transfer_records', record.toMap());
    return record.copyWith(id: id);
  }

  /// Update an existing transfer record.
  Future<int> update(TransferRecord record) async {
    if (record.id == null) {
      throw ArgumentError('Cannot update record without id');
    }
    final db = _requireDb();
    return await db.update(
      'transfer_records',
      record.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  /// Update the status of a transfer record.
  Future<int> updateStatus(int id, TransferStatus status,
      {int? durationMs, String? errorMessage}) async {
    final db = _requireDb();
    final values = <String, dynamic>{'status': status.index};
    if (durationMs != null) values['duration_ms'] = durationMs;
    if (errorMessage != null) values['error_message'] = errorMessage;

    return await db.update(
      'transfer_records',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get a transfer record by ID.
  Future<TransferRecord?> getById(int id) async {
    final db = _requireDb();
    final maps = await db.query(
      'transfer_records',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return TransferRecord.fromMap(maps.first);
  }

  /// Query transfer records with optional filter.
  Future<List<TransferRecord>> query({
    TransferFilter? filter,
    int? limit,
    int? offset,
    String orderBy = 'timestamp DESC',
  }) async {
    final db = _requireDb();
    String where = '';
    List<dynamic>? whereArgs;

    if (filter != null) {
      final (w, args) = filter.buildWhereClause();
      where = w;
      whereArgs = args.isEmpty ? null : args;
    }

    final maps = await db.query(
      'transfer_records',
      where: where.isEmpty ? null : where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );

    return maps.map(TransferRecord.fromMap).toList();
  }

  /// Get all records for a specific device.
  Future<List<TransferRecord>> getByDevice(String deviceName) async {
    return query(filter: TransferFilter(deviceName: deviceName));
  }

  /// Get records with a specific status.
  Future<List<TransferRecord>> getByStatus(TransferStatus status) async {
    return query(filter: TransferFilter(status: status));
  }

  /// Get recent transfers (last N entries).
  Future<List<TransferRecord>> getRecent({int count = 20}) async {
    return query(limit: count, orderBy: 'timestamp DESC');
  }

  /// Get count of records matching filter.
  Future<int> count({TransferFilter? filter}) async {
    final db = _requireDb();
    String where = '';
    List<dynamic>? whereArgs;

    if (filter != null) {
      final (w, args) = filter.buildWhereClause();
      where = w;
      whereArgs = args.isEmpty ? null : args;
    }

    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM transfer_records $where',
      whereArgs,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Delete a transfer record by ID.
  Future<int> delete(int id) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete records older than the given timestamp.
  Future<int> deleteOlderThan(int timestamp) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'timestamp < ?',
      whereArgs: [timestamp],
    );
  }

  /// Delete all records with a specific status.
  Future<int> deleteByStatus(TransferStatus status) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'status = ?',
      whereArgs: [status.index],
    );
  }

  /// Close the database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Database _requireDb() {
    if (_db == null) {
      throw StateError('Database not initialized. Call init() first.');
    }
    return _db!;
  }
}
