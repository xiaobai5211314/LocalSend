import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Filter criteria for querying transfer history.
///
/// All fields are optional; only non-null fields are applied as filters.
class TransferFilter {
  /// Filter by device name (matches either from_device or to_device).
  final String? deviceName;

  /// Filter by transfer status.
  final TransferStatus? status;

  /// Filter by transfer direction.
  final TransferDirection? direction;

  /// Inclusive start of timestamp range (Unix ms).
  final int? startTime;

  /// Inclusive end of timestamp range (Unix ms).
  final int? endTime;

  /// Search pattern for file names (SQL LIKE, '%' wildcards auto-applied).
  final String? fileNamePattern;

  TransferFilter({
    this.deviceName,
    this.status,
    this.direction,
    this.startTime,
    this.endTime,
    this.fileNamePattern,
  });

  /// Build SQL WHERE clause and bound parameters from this filter.
  (String whereClause, List<dynamic> params) buildWhereClause() {
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
    if (direction != null) {
      conditions.add('direction = ?');
      params.add(direction!.index);
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

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';
    return (where, params);
  }
}

/// SQLite-backed transfer history service.
///
/// Provides CRUD operations for [TransferRecord] with filtering by
/// device, status, direction, time range, and file name patterns.
/// Supports one-click retransmission by returning original file paths.
class HistoryService {
  static HistoryService? _instance;
  Database? _db;

  HistoryService._();

  /// Get singleton instance.
  static HistoryService get instance {
    _instance ??= HistoryService._();
    return _instance!;
  }

  /// Whether the database has been initialized.
  bool get isInitialized => _db != null;

  // ============================================================
  // Initialization
  // ============================================================

  /// Initialize the database at the given path and create tables.
  Future<void> init(String dbPath) async {
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: _onCreate,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transfer_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_device TEXT NOT NULL,
        to_device TEXT NOT NULL,
        file_names TEXT NOT NULL,
        total_size INTEGER NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        timestamp INTEGER NOT NULL,
        direction INTEGER NOT NULL DEFAULT 0,
        original_paths TEXT,
        duration_ms INTEGER,
        error_message TEXT
      )
    ''');

    // Index for time-ordered queries
    await db.execute('''
      CREATE INDEX idx_history_timestamp
      ON transfer_records(timestamp DESC)
    ''');

    // Index for status-based filtering
    await db.execute('''
      CREATE INDEX idx_history_status
      ON transfer_records(status)
    ''');

    // Index for device-based filtering
    await db.execute('''
      CREATE INDEX idx_history_devices
      ON transfer_records(from_device, to_device)
    ''');

    // Index for direction-based queries
    await db.execute('''
      CREATE INDEX idx_history_direction
      ON transfer_records(direction)
    ''');
  }

  // ============================================================
  // Create
  // ============================================================

  /// Insert a new transfer record.
  ///
  /// Returns the record with its assigned database ID.
  Future<TransferRecord> insert(TransferRecord record) async {
    final db = _requireDb();
    final id = await db.insert('transfer_records', record.toMap());
    return record.copyWith(id: id);
  }

  // ============================================================
  // Read - Single
  // ============================================================

  /// Get a transfer record by its ID.
  ///
  /// Returns null if no record with the given ID exists.
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

  // ============================================================
  // Read - Query
  // ============================================================

  /// Query transfer records with optional filter and pagination.
  ///
  /// Results are ordered by [orderBy] (default: timestamp descending).
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
      whereArgs = args.isNotEmpty ? args : null;
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

  /// Get all records involving a specific device.
  Future<List<TransferRecord>> getByDevice(String deviceName) async {
    return query(filter: TransferFilter(deviceName: deviceName));
  }

  /// Get records with a specific status.
  Future<List<TransferRecord>> getByStatus(TransferStatus status) async {
    return query(filter: TransferFilter(status: status));
  }

  /// Get records with a specific direction.
  Future<List<TransferRecord>> getByDirection(
      TransferDirection direction) async {
    return query(filter: TransferFilter(direction: direction));
  }

  /// Get the N most recent transfer records.
  Future<List<TransferRecord>> getRecent({int count = 20}) async {
    return query(limit: count, orderBy: 'timestamp DESC');
  }

  /// Get all failed transfers (for retry purposes).
  Future<List<TransferRecord>> getFailed() async {
    return query(filter: TransferFilter(status: TransferStatus.failed));
  }

  /// Get transfers within a time range.
  Future<List<TransferRecord>> getByTimeRange(
      int startTime, int endTime) async {
    return query(
        filter: TransferFilter(startTime: startTime, endTime: endTime));
  }

  /// Search transfers by file name keyword.
  Future<List<TransferRecord>> searchByFileName(String keyword) async {
    return query(filter: TransferFilter(fileNamePattern: keyword));
  }

  // ============================================================
  // Read - Count
  // ============================================================

  /// Count records matching the given filter.
  Future<int> count({TransferFilter? filter}) async {
    final db = _requireDb();
    String where = '';
    List<dynamic>? whereArgs;

    if (filter != null) {
      final (w, args) = filter.buildWhereClause();
      where = w;
      whereArgs = args.isNotEmpty ? args : null;
    }

    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM transfer_records $where',
      whereArgs,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ============================================================
  // Update
  // ============================================================

  /// Update an existing transfer record.
  ///
  /// The record must have a non-null [id].
  Future<int> update(TransferRecord record) async {
    if (record.id == null) {
      throw ArgumentError('Cannot update a record without an id');
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
  ///
  /// Optionally sets [durationMs] and [errorMessage] in the same operation.
  Future<int> updateStatus(
    int id,
    TransferStatus status, {
    int? durationMs,
    String? errorMessage,
  }) async {
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

  // ============================================================
  // Delete
  // ============================================================

  /// Delete a transfer record by its ID.
  ///
  /// Returns the number of rows deleted (0 or 1).
  Future<int> delete(int id) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete all records older than the given timestamp.
  ///
  /// Returns the number of rows deleted.
  Future<int> deleteOlderThan(int timestamp) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'timestamp < ?',
      whereArgs: [timestamp],
    );
  }

  /// Delete all records with a specific status.
  ///
  /// Returns the number of rows deleted.
  Future<int> deleteByStatus(TransferStatus status) async {
    final db = _requireDb();
    return await db.delete(
      'transfer_records',
      where: 'status = ?',
      whereArgs: [status.index],
    );
  }

  // ============================================================
  // Retransmission Support
  // ============================================================

  /// Get the original file paths for a transfer record.
  ///
  /// Returns null if paths are not available or the record doesn't exist.
  /// These paths can be passed to the transport module for retransmission.
  Future<List<String>?> getRetransmitPaths(int id) async {
    final record = await getById(id);
    if (record == null) return null;

    // Only allow retransmission of failed or cancelled sent transfers
    if (record.direction != TransferDirection.sent) return null;
    if (record.status == TransferStatus.completed) return null;

    return record.originalPaths;
  }

  /// Check if a record can be retransmitted.
  Future<bool> canRetransmit(int id) async {
    final record = await getById(id);
    return record?.canRetransmit ?? false;
  }

  // ============================================================
  // Lifecycle
  // ============================================================

  /// Close the database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Require database to be initialized, throw if not.
  Database _requireDb() {
    if (_db == null) {
      throw StateError(
          'HistoryService not initialized. Call init() before using.');
    }
    return _db!;
  }
}
