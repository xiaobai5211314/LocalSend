import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'transfer_history.dart';

/// Represents the resume state for a single file transfer.
class FileResumeState {
  /// Transfer record ID from the database.
  final int transferId;
  /// Transfer session ID (matches the Rust transport layer).
  final String transferSessionId;
  /// Set of already-received chunk indices.
  final Set<int> receivedChunks;
  /// Total number of chunks.
  final int totalChunks;
  /// Path to the partial output file.
  final String partialFilePath;
  /// Original file name.
  final String fileName;
  /// Total file size in bytes.
  final int fileSize;
  /// SHA-256 hash of the expected complete file.
  final String fullHash;
  /// Timestamp of last received chunk.
  final int lastUpdateTimestamp;
  /// Device ID of the sender.
  final String senderDeviceId;

  FileResumeState({
    required this.transferId,
    required this.transferSessionId,
    required this.receivedChunks,
    required this.totalChunks,
    required this.partialFilePath,
    required this.fileName,
    required this.fileSize,
    required this.fullHash,
    required this.lastUpdateTimestamp,
    required this.senderDeviceId,
  });

  /// Whether any chunks have been received.
  bool get hasProgress => receivedChunks.isNotEmpty;

  /// Progress percentage (0-100).
  double get progressPercent => totalChunks > 0
      ? (receivedChunks.length / totalChunks) * 100.0
      : 0.0;

  /// Set of missing chunk indices.
  Set<int> get missingChunks {
    final all = Set<int>.from(Iterable.generate(totalChunks));
    return all.difference(receivedChunks);
  }

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'transfer_session_id': transferSessionId,
        'received_chunks': receivedChunks.toList(),
        'total_chunks': totalChunks,
        'partial_file_path': partialFilePath,
        'file_name': fileName,
        'file_size': fileSize,
        'full_hash': fullHash,
        'last_update_timestamp': lastUpdateTimestamp,
        'sender_device_id': senderDeviceId,
      };

  factory FileResumeState.fromJson(Map<String, dynamic> json) {
    return FileResumeState(
      transferId: json['transfer_id'] as int,
      transferSessionId: json['transfer_session_id'] as String,
      receivedChunks: Set<int>.from(json['received_chunks'] as List),
      totalChunks: json['total_chunks'] as int,
      partialFilePath: json['partial_file_path'] as String,
      fileName: json['file_name'] as String,
      fileSize: json['file_size'] as int,
      fullHash: json['full_hash'] as String,
      lastUpdateTimestamp: json['last_update_timestamp'] as int,
      senderDeviceId: json['sender_device_id'] as String,
    );
  }
}

/// Manages breakpoint-resume state for file transfers.
///
/// Persists resume information to disk so that interrupted transfers
/// can be resumed from where they left off after reconnection.
class ResumeManager {
  static ResumeManager? _instance;
  final Map<String, FileResumeState> _activeTransfers = {};
  String? _storagePath;

  ResumeManager._();

  /// Get singleton instance.
  static ResumeManager get instance {
    _instance ??= ResumeManager._();
    return _instance!;
  }

  /// Initialize the resume manager and load persisted state.
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _storagePath = '${dir.path}/localsend_resume';
    final storageDir = Directory(_storagePath!);
    if (!await storageDir.exists()) {
      await storageDir.create(recursive: true);
    }
    await _loadPersistedState();
  }

  /// Start tracking a new transfer for resume support.
  FileResumeState startTracking({
    required int transferId,
    required String transferSessionId,
    required int totalChunks,
    required String partialFilePath,
    required String fileName,
    required int fileSize,
    required String fullHash,
    required String senderDeviceId,
  }) {
    final state = FileResumeState(
      transferId: transferId,
      transferSessionId: transferSessionId,
      receivedChunks: {},
      totalChunks: totalChunks,
      partialFilePath: partialFilePath,
      fileName: fileName,
      fileSize: fileSize,
      fullHash: fullHash,
      lastUpdateTimestamp: DateTime.now().millisecondsSinceEpoch,
      senderDeviceId: senderDeviceId,
    );

    _activeTransfers[transferSessionId] = state;
    _persistState(state);

    return state;
  }

  /// Register a successfully received chunk.
  FileResumeState? recordChunkReceived(
    String transferSessionId,
    int chunkIndex,
  ) {
    final state = _activeTransfers[transferSessionId];
    if (state == null) return null;

    state.receivedChunks.add(chunkIndex);
    final updated = FileResumeState(
      transferId: state.transferId,
      transferSessionId: state.transferSessionId,
      receivedChunks: state.receivedChunks,
      totalChunks: state.totalChunks,
      partialFilePath: state.partialFilePath,
      fileName: state.fileName,
      fileSize: state.fileSize,
      fullHash: state.fullHash,
      lastUpdateTimestamp: DateTime.now().millisecondsSinceEpoch,
      senderDeviceId: state.senderDeviceId,
    );

    _activeTransfers[transferSessionId] = updated;
    _persistState(updated);

    return updated;
  }

  /// Get resume state for a transfer session.
  FileResumeState? getState(String transferSessionId) {
    return _activeTransfers[transferSessionId];
  }

  /// Get all active (non-completed) resume states.
  List<FileResumeState> get activeTransfers => _activeTransfers.values.toList();

  /// Check if there are any pending transfers to resume.
  bool get hasPendingTransfers => _activeTransfers.values.any(
        (s) => s.receivedChunks.length < s.totalChunks,
      );

  /// Get all transfers that can be resumed.
  List<FileResumeState> get resumableTransfers => _activeTransfers.values
      .where((s) =>
          s.receivedChunks.isNotEmpty && s.receivedChunks.length < s.totalChunks)
      .toList();

  /// Mark a transfer as complete and remove its resume state.
  Future<void> markComplete(String transferSessionId) async {
    _activeTransfers.remove(transferSessionId);
    await _deletePersistedState(transferSessionId);
  }

  /// Cancel a transfer and remove its resume state.
  Future<void> cancel(String transferSessionId) async {
    final state = _activeTransfers.remove(transferSessionId);
    if (state != null) {
      await _deletePersistedState(transferSessionId);
      // Optionally delete the partial file
      final file = File(state.partialFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Persist a single transfer state to disk.
  Future<void> _persistState(FileResumeState state) async {
    if (_storagePath == null) return;
    final file = File('$_storagePath/${state.transferSessionId}.json');
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  /// Delete persisted state for a transfer session.
  Future<void> _deletePersistedState(String transferSessionId) async {
    if (_storagePath == null) return;
    final file = File('$_storagePath/$transferSessionId.json');
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Load all persisted resume states from disk.
  Future<void> _loadPersistedState() async {
    if (_storagePath == null) return;

    final dir = Directory(_storagePath!);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final state = FileResumeState.fromJson(json);

          // Only load incomplete transfers
          if (state.receivedChunks.length < state.totalChunks) {
            _activeTransfers[state.transferSessionId] = state;
          } else {
            // Stale completed; clean up
            await entity.delete();
          }
        } catch (_) {
          // Corrupted file; delete it
          await entity.delete();
        }
      }
    }
  }
}
