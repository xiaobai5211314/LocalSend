import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class TransferRecord {
  final int? id;
  final String fileName;
  final int fileSize;
  final String direction; // sent / received
  final String remoteDevice;
  final String status; // pending / transferring / completed / failed
  final int progress;
  final DateTime createdAt;
  final String? localPath;

  TransferRecord({
    this.id,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.remoteDevice,
    this.status = 'pending',
    this.progress = 0,
    DateTime? createdAt,
    this.localPath,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'file_name': fileName,
        'file_size': fileSize,
        'direction': direction,
        'remote_device': remoteDevice,
        'status': status,
        'progress': progress,
        'created_at': createdAt.toIso8601String(),
        'local_path': localPath,
      };

  factory TransferRecord.fromMap(Map<String, dynamic> map) => TransferRecord(
        id: map['id'],
        fileName: map['file_name'],
        fileSize: map['file_size'],
        direction: map['direction'],
        remoteDevice: map['remote_device'],
        status: map['status'] ?? 'pending',
        progress: map['progress'] ?? 0,
        createdAt: DateTime.parse(map['created_at']),
        localPath: map['local_path'],
      );
}

class TransferHistoryService {
  static TransferHistoryService? _instance;
  Database? _db;
  final _recordsController = StreamController<List<TransferRecord>>.broadcast();
  Stream<List<TransferRecord>> get recordsStream => _recordsController.stream;

  TransferHistoryService._();

  factory TransferHistoryService() {
    _instance ??= TransferHistoryService._();
    return _instance!;
  }

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'transfer_history.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE transfers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_name TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          direction TEXT NOT NULL,
          remote_device TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          progress INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          local_path TEXT
        )
      ''');
    });
    return _db!;
  }

  Future<int> addRecord(TransferRecord record) async {
    final database = await db;
    return database.insert('transfers', record.toMap());
  }

  Future<void> updateProgress(int id, int progress, String status) async {
    final database = await db;
    await database.update('transfers', {'progress': progress, 'status': status}, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<TransferRecord>> getRecords({int limit = 50, int offset = 0}) async {
    final database = await db;
    final maps = await database.query('transfers', orderBy: 'created_at DESC', limit: limit, offset: offset);
    return maps.map((m) => TransferRecord.fromMap(m)).toList();
  }

  Future<void> deleteRecord(int id) async {
    final database = await db;
    await database.delete('transfers', where: 'id = ?', whereArgs: [id]);
  }

  void dispose() {
    _recordsController.close();
    _db?.close();
  }
}
