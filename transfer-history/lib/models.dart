import 'dart:convert';

/// Data models for the transfer history module.
///
/// Defines the core [TransferRecord] and supporting types used by
/// [HistoryService] and [ResumeManager].

/// Transfer direction classification.
enum TransferDirection {
  /// Sent from this device to another device.
  sent,
  /// Received from another device to this device.
  received,
}

/// Transfer status enumeration.
enum TransferStatus {
  /// Transfer completed successfully.
  completed,
  /// Transfer failed (network error, checksum mismatch, etc.).
  failed,
  /// Transfer was explicitly cancelled by user.
  cancelled,
}

/// Extension helpers for [TransferStatus].
extension TransferStatusExtension on TransferStatus {
  /// Human-readable status text.
  String get label {
    switch (this) {
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.failed:
        return 'Failed';
      case TransferStatus.cancelled:
        return 'Cancelled';
    }
  }
}

/// Extension helpers for [TransferDirection].
extension TransferDirectionExtension on TransferDirection {
  /// Human-readable direction text.
  String get label {
    switch (this) {
      case TransferDirection.sent:
        return 'Sent';
      case TransferDirection.received:
        return 'Received';
    }
  }
}

/// A single file transfer record stored in the transfer history database.
///
/// Each record represents one complete transfer (which may include
/// multiple files). The file names are stored as a JSON-encoded list
/// in the database, and deserialized to a Dart List here.
class TransferRecord {
  /// Auto-incremented primary key (null until persisted).
  final int? id;

  /// Name/ID of the sending device.
  final String fromDevice;

  /// Name/ID of the receiving device.
  final String toDevice;

  /// List of file names included in this transfer.
  final List<String> fileNames;

  /// Total size of all files in bytes.
  final int totalSize;

  /// Transfer result status.
  final TransferStatus status;

  /// Unix timestamp (milliseconds) when the transfer was created.
  final int timestamp;

  /// Whether this transfer was sent or received.
  final TransferDirection direction;

  /// Original file paths on disk (for retransmission support).
  /// Null if paths are unavailable or the files have been moved.
  final List<String>? originalPaths;

  /// Transfer duration in milliseconds (null if interrupted).
  final int? durationMs;

  /// Error message if the transfer failed.
  final String? errorMessage;

  TransferRecord({
    this.id,
    required this.fromDevice,
    required this.toDevice,
    required this.fileNames,
    required this.totalSize,
    required this.status,
    required this.timestamp,
    required this.direction,
    this.originalPaths,
    this.durationMs,
    this.errorMessage,
  });

  /// Create a [TransferRecord] from a database row map.
  factory TransferRecord.fromMap(Map<String, dynamic> map) {
    return TransferRecord(
      id: map['id'] as int?,
      fromDevice: map['from_device'] as String,
      toDevice: map['to_device'] as String,
      fileNames: _parseFileNames(map['file_names']),
      totalSize: map['total_size'] as int,
      status: TransferStatus.values[map['status'] as int],
      timestamp: map['timestamp'] as int,
      direction: TransferDirection.values[map['direction'] as int],
      originalPaths: _parseStringList(map['original_paths']),
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
      'file_names': jsonEncode(fileNames),
      'total_size': totalSize,
      'status': status.index,
      'timestamp': timestamp,
      'direction': direction.index,
      'original_paths':
          originalPaths != null ? jsonEncode(originalPaths) : null,
      'duration_ms': durationMs,
      'error_message': errorMessage,
    };
  }

  /// Human-readable total size string (e.g., "1.5 MB").
  String get totalSizeText {
    if (totalSize < 1024) return '$totalSize B';
    if (totalSize < 1024 * 1024) {
      return '${(totalSize / 1024).toStringAsFixed(1)} KB';
    }
    if (totalSize < 1024 * 1024 * 1024) {
      return '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Comma-separated list of file names for display.
  String get fileNamesDisplay => fileNames.join(', ');

  /// Whether this transfer can be retransmitted (paths are available).
  bool get canRetransmit =>
      originalPaths != null && originalPaths!.isNotEmpty;

  /// Whether the transfer was successful.
  bool get isCompleted => status == TransferStatus.completed;

  /// Create a copy with optional overrides.
  TransferRecord copyWith({
    int? id,
    String? fromDevice,
    String? toDevice,
    List<String>? fileNames,
    int? totalSize,
    TransferStatus? status,
    int? timestamp,
    TransferDirection? direction,
    List<String>? originalPaths,
    int? durationMs,
    String? errorMessage,
  }) {
    return TransferRecord(
      id: id ?? this.id,
      fromDevice: fromDevice ?? this.fromDevice,
      toDevice: toDevice ?? this.toDevice,
      fileNames: fileNames ?? this.fileNames,
      totalSize: totalSize ?? this.totalSize,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      direction: direction ?? this.direction,
      originalPaths: originalPaths ?? this.originalPaths,
      durationMs: durationMs ?? this.durationMs,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  String toString() {
    return 'TransferRecord(id=$id, from=$fromDevice, to=$toDevice, '
        'files=${fileNames.length}, size=$totalSizeText, '
        'status=${status.label}, direction=${direction.label})';
  }
}

// ============================================================
// Internal helpers
// ============================================================

/// Parse a database value into a list of file name strings.
List<String> _parseFileNames(dynamic value) {
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
      return [value];
    } catch (_) {
      return [value];
    }
  }
  if (value is List) {
    return value.map((e) => e.toString()).toList();
  }
  return [];
}

/// Parse a nullable database value into a list of strings or null.
List<String>? _parseStringList(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        final list = decoded.map((e) => e.toString()).toList();
        return list.isEmpty ? null : list;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
  if (value is List) {
    final list = value.map((e) => e.toString()).toList();
    return list.isEmpty ? null : list;
  }
  return null;
}
