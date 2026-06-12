import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Types of file change events.
enum SyncEventType { created, modified, deleted }

/// Represents a file change event for syncing.
class SyncEvent {
  final SyncEventType type;
  final String filePath;
  final String relativePath;
  final int timestampMs;
  final int? fileSize;

  SyncEvent({
    required this.type,
    required this.filePath,
    required this.relativePath,
    required this.timestampMs,
    this.fileSize,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'file_path': filePath,
        'relative_path': relativePath,
        'timestamp_ms': timestampMs,
        if (fileSize != null) 'file_size': fileSize,
      };

  factory SyncEvent.fromJson(Map<String, dynamic> json) => SyncEvent(
        type: SyncEventType.values.byName(json['type'] as String),
        filePath: json['file_path'] as String,
        relativePath: json['relative_path'] as String,
        timestampMs: json['timestamp_ms'] as int,
        fileSize: json['file_size'] as int?,
      );
}

/// A paired device that receives folder sync events.
class PairedDevice {
  final String deviceId;
  final String deviceName;
  final String? platform;

  PairedDevice({
    required this.deviceId,
    required this.deviceName,
    this.platform,
  });

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_name': deviceName,
        if (platform != null) 'platform': platform,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceId: json['device_id'] as String,
        deviceName: json['device_name'] as String,
        platform: json['platform'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is PairedDevice && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Configuration for a single synchronized folder.
class SyncFolderConfig {
  final String localPath;
  final Set<PairedDevice> pairedDevices;
  bool isActive;

  SyncFolderConfig({
    required this.localPath,
    Set<PairedDevice>? pairedDevices,
    this.isActive = true,
  }) : pairedDevices = pairedDevices ?? {};

  Map<String, dynamic> toJson() => {
        'local_path': localPath,
        'devices': pairedDevices.map((d) => d.toJson()).toList(),
        'is_active': isActive,
      };

  factory SyncFolderConfig.fromJson(Map<String, dynamic> json) {
    final devices = (json['devices'] as List<dynamic>?)
            ?.map((d) => PairedDevice.fromJson(d as Map<String, dynamic>))
            .toSet() ??
        <PairedDevice>{};
    return SyncFolderConfig(
      localPath: json['local_path'] as String,
      pairedDevices: devices,
      isActive: json['is_active'] as bool? ?? true,
    );
  }
}

/// Callback for sync events that should be sent to paired devices.
typedef SyncEventCallback = Future<void> Function(
    SyncEvent event, Set<PairedDevice> targetDevices);

/// Callback for receiving sync events from remote devices.
typedef RemoteSyncCallback = Future<void> Function(
    SyncEvent event, String fromDeviceId);

/// Folder Sync Service
///
/// Manages multiple synchronized folders, each paired with specific
/// devices. Detects local file changes and sends them to paired devices.
/// Receives remote changes and writes them locally with conflict resolution.
///
/// Features:
/// - Multi-folder management (add/remove folders)
/// - Paired device management per folder
/// - File hash tracking for deduplication (SharedPreferences)
/// - Conflict resolution: .conflict.{timestamp} renaming
/// - Config persistence
class FolderSyncService {
  final Map<String, SyncFolderConfig> _folders = {};
  final Map<String, String> _fileHashes = {};
  SharedPreferences? _prefs;

  static const String _hashPrefix = 'folder_sync_hash_';
  static const String _configKey = 'folder_sync_config';

  /// Callback to send sync events to remote devices.
  SyncEventCallback? onSyncEvent;

  /// Callback when receiving sync events from remote devices.
  RemoteSyncCallback? onRemoteSync;

  /// Create a new FolderSyncService.
  FolderSyncService({
    this.onSyncEvent,
    this.onRemoteSync,
  });

  /// All currently configured sync folders.
  List<SyncFolderConfig> get folders => _folders.values.toList();

  /// Active sync folders.
  List<SyncFolderConfig> get activeFolders =>
      _folders.values.where((f) => f.isActive).toList();

  // ============================================================
  // Initialization / Persistence
  // ============================================================

  /// Initialize the service and load persisted state.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadConfig();
    await _loadHashes();
  }

  Future<void> _loadConfig() async {
    final raw = _prefs?.getString(_configKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final config =
            SyncFolderConfig.fromJson(item as Map<String, dynamic>);
        _folders[config.localPath] = config;
      }
    } catch (_) {
      // Corrupt config, reset
    }
  }

  Future<void> _saveConfig() async {
    final data = _folders.values.map((f) => f.toJson()).toList();
    await _prefs?.setString(_configKey, jsonEncode(data));
  }

  Future<void> _loadHashes() async {
    final keys = _prefs?.getKeys() ?? <String>{};
    for (final key in keys) {
      if (key.startsWith(_hashPrefix)) {
        final filePath = key.substring(_hashPrefix.length);
        final hash = _prefs?.getString(key);
        if (hash != null) {
          _fileHashes[filePath] = hash;
        }
      }
    }
  }

  Future<void> _saveHash(String filePath, String hash) async {
    await _prefs?.setString('$_hashPrefix$filePath', hash);
  }

  // ============================================================
  // Folder Management
  // ============================================================

  /// Add a folder for syncing.
  Future<void> addFolder(String localPath) async {
    if (_folders.containsKey(localPath)) return;

    final dir = Directory(localPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final config = SyncFolderConfig(localPath: localPath);
    _folders[localPath] = config;
    await _saveConfig();
  }

  /// Remove a folder from syncing.
  Future<void> removeFolder(String localPath) async {
    _folders.remove(localPath);
    await _saveConfig();
  }

  /// Activate a sync folder.
  Future<void> activateFolder(String localPath) async {
    final folder = _folders[localPath];
    if (folder != null) {
      folder.isActive = true;
      await _saveConfig();
    }
  }

  /// Deactivate a sync folder.
  Future<void> deactivateFolder(String localPath) async {
    final folder = _folders[localPath];
    if (folder != null) {
      folder.isActive = false;
      await _saveConfig();
    }
  }

  // ============================================================
  // Paired Device Management
  // ============================================================

  /// Add a paired device to a sync folder.
  Future<void> addDeviceToFolder(
      String localPath, PairedDevice device) async {
    final folder = _folders[localPath];
    if (folder == null) return;

    folder.pairedDevices.add(device);
    await _saveConfig();
  }

  /// Remove a paired device from a sync folder.
  Future<void> removeDeviceFromFolder(
      String localPath, String deviceId) async {
    final folder = _folders[localPath];
    if (folder == null) return;

    folder.pairedDevices.removeWhere((d) => d.deviceId == deviceId);
    await _saveConfig();
  }

  /// Get paired devices for a folder.
  Set<PairedDevice> getDevicesForFolder(String localPath) {
    return _folders[localPath]?.pairedDevices ?? <PairedDevice>{};
  }

  // ============================================================
  // File Change Handling (Local -> Remote)
  // ============================================================

  /// Handle a local file change event.
  ///
  /// Computes the file hash, checks deduplication, and triggers
  /// sync to paired devices if the content has changed.
  Future<void> handleLocalChange(
    String absolutePath,
    SyncEventType eventType,
  ) async {
    // Find which sync folder this file belongs to
    SyncFolderConfig? folder;
    String? relativePath;

    for (final f in _folders.values) {
      if (!f.isActive) continue;
      final normFolder = _normalize(f.localPath);
      final normFile = _normalize(absolutePath);
      if (normFile.startsWith(normFolder)) {
        folder = f;
        relativePath = absolutePath.substring(f.localPath.length);
        if (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
          relativePath = relativePath.substring(1);
        }
        break;
      }
    }

    if (folder == null || folder.pairedDevices.isEmpty) return;

    // Compute file hash for deduplication (skip deleted files)
    String? hash;
    int? fileSize;
    if (eventType != SyncEventType.deleted) {
      try {
        final file = File(absolutePath);
        if (await file.exists()) {
          fileSize = await file.length();
          final bytes = await file.readAsBytes();
          hash = sha256.convert(bytes).toString();
        }
      } catch (_) {
        return; // Cannot read file, skip
      }
    }

    // Deduplication: skip if hash unchanged
    if (hash != null) {
      final prevHash = _fileHashes[absolutePath];
      if (prevHash == hash) return;
      await _saveHash(absolutePath, hash);
    }

    final event = SyncEvent(
      type: eventType,
      filePath: absolutePath,
      relativePath: relativePath!,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      fileSize: fileSize,
    );

    await onSyncEvent?.call(event, folder.pairedDevices);
  }

  // ============================================================
  // Remote Change Handling (Remote -> Local)
  // ============================================================

  /// Handle a sync event received from a remote device.
  ///
  /// Writes the file to the corresponding local folder with conflict
  /// resolution.
  Future<void> handleRemoteChange(
    SyncEvent event,
    String fromDeviceId,
    List<int> fileData,
  ) async {
    // Find folder paired with this device
    SyncFolderConfig? folder;
    for (final f in _folders.values) {
      if (!f.isActive) continue;
      if (f.pairedDevices.any((d) => d.deviceId == fromDeviceId)) {
        folder = f;
        break;
      }
    }

    if (folder == null) {
      onRemoteSync?.call(event, fromDeviceId);
      return;
    }

    final targetPath = p.join(folder.localPath, event.relativePath);

    switch (event.type) {
      case SyncEventType.created:
      case SyncEventType.modified:
        await _writeRemoteFile(targetPath, event, fileData);
        break;
      case SyncEventType.deleted:
        final file = File(targetPath);
        if (await file.exists()) {
          await file.delete();
        }
        break;
    }
  }

  /// Write incoming file data with conflict resolution.
  Future<void> _writeRemoteFile(
    String targetPath,
    SyncEvent event,
    List<int> fileData,
  ) async {
    final targetFile = File(targetPath);
    final targetDir = targetFile.parent;

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    if (await targetFile.exists()) {
      // Conflict: rename existing file to .conflict.{timestamp}
      final conflictName =
          '${p.basename(targetPath)}.conflict.${DateTime.now().millisecondsSinceEpoch}';
      final conflictPath = p.join(targetDir.path, conflictName);
      await targetFile.rename(conflictPath);
    }

    // Write the incoming file data
    await targetFile.writeAsBytes(fileData);

    // Update hash tracking
    final hash = sha256.convert(fileData).toString();
    await _saveHash(targetPath, hash);
  }

  // ============================================================
  // Helpers
  // ============================================================

  /// Check if a path is within any sync folder.
  bool isSyncedPath(String absolutePath) {
    final norm = _normalize(absolutePath);
    for (final f in _folders.values) {
      if (!f.isActive) continue;
      if (norm.startsWith(_normalize(f.localPath))) return true;
    }
    return false;
  }

  /// Compute SHA-256 hash of a file on disk.
  String? computeFileHash(String filePath) {
    try {
      final bytes = File(filePath).readAsBytesSync();
      return sha256.convert(bytes).toString();
    } catch (_) {
      return null;
    }
  }

  /// Get hashed files count for a folder.
  int getTrackedFileCount(String folderPath) {
    return _fileHashes.keys
        .where((k) => _normalize(k).startsWith(_normalize(folderPath)))
        .length;
  }

  /// Clear all persisted state.
  Future<void> clearAll() async {
    _folders.clear();
    _fileHashes.clear();
    await _prefs?.clear();
  }

  /// Release resources.
  void dispose() {
    _folders.clear();
    _fileHashes.clear();
    _prefs = null;
  }

  String _normalize(String path) =>
      path.replaceAll('\\', '/').toLowerCase().replaceAll(RegExp(r'/+$'), '');
}
