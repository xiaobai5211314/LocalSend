import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Types of file system events detected by the watcher.
enum FileEventType { created, modified, deleted }

/// A detected file system change event.
class FileWatchEvent {
  final String path;
  final FileEventType eventType;
  final DateTime timestamp;

  FileWatchEvent({
    required this.path,
    required this.eventType,
    required this.timestamp,
  });

  @override
  String toString() =>
      'FileWatchEvent($eventType: $path @ $timestamp)';
}

/// Cross-platform file watcher using [Directory.list] polling.
///
/// Recursive directory monitoring with debounce (200ms default)
/// and blacklist filtering for temporary, system, and build files.
///
/// Platform-agnostic: works on Windows, macOS, Linux, Android, iOS
/// via recursive directory listing with modification time comparison.
class FileWatcher {
  final String directoryPath;
  final bool recursive;
  final Duration debounceDelay;
  final Duration pollInterval;

  /// Paths matching these patterns are excluded from events.
  final List<String> _blacklist;
  static const List<String> defaultBlacklist = [
    '.tmp',
    '.swp',
    '.lock',
    '.crdownload',
    '~$',
    'Thumbs.db',
    'desktop.ini',
    '.DS_Store',
    'node_modules',
    '.git',
    '__pycache__',
    '.idea',
    '.vs',
    '.vscode',
  ];

  final Map<String, DateTime> _lastModified = {};
  final Map<String, Timer> _debounceTimers = {};
  Timer? _pollTimer;
  bool _running = false;

  /// Callback invoked with deduplicated, debounced file change events.
  final void Function(List<FileWatchEvent> events)? onChanged;

  FileWatcher({
    required this.directoryPath,
    this.recursive = true,
    this.debounceDelay = const Duration(milliseconds: 200),
    this.pollInterval = const Duration(milliseconds: 500),
    List<String>? blacklist,
    this.onChanged,
  }) : _blacklist = blacklist ?? defaultBlacklist;

  /// Whether the watcher is currently active.
  bool get isRunning => _running;

  /// Start watching the directory for file changes.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Initial scan: record modification times for all existing files
    await _initialScan(dir);

    // Start polling loop
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollDirectory(dir));
  }

  /// Stop watching and release all resources.
  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    _lastModified.clear();
  }

  // ============================================================
  // Initial Scan
  // ============================================================

  Future<void> _initialScan(Directory dir) async {
    try {
      final entities = dir.listSync(recursive: recursive, followLinks: false);
      for (final entity in entities) {
        if (entity is File && !_isBlacklisted(entity.path)) {
          _lastModified[entity.path] = await entity.lastModified();
        }
      }
    } catch (_) {
      // Directory may be inaccessible; skip
    }
  }

  // ============================================================
  // Polling
  // ============================================================

  Future<void> _pollDirectory(Directory dir) async {
    if (!_running) return;

    try {
      final entities = dir.listSync(recursive: recursive, followLinks: false);
      final changedEvents = <FileWatchEvent>[];

      // Track currently known paths to detect deletions
      final currentPaths = <String>{};

      for (final entity in entities) {
        if (entity is! File) continue;
        if (_isBlacklisted(entity.path)) continue;

        final path = entity.path;
        currentPaths.add(path);

        final prevMtime = _lastModified[path];

        if (prevMtime == null) {
          // New file created
          final mtime = await entity.lastModified();
          _lastModified[path] = mtime;
          _enqueueDebouncedEvent(
            FileWatchEvent(
                path: path,
                eventType: FileEventType.created,
                timestamp: DateTime.now()),
          );
        } else {
          final mtime = await entity.lastModified();
          if (mtime.isAfter(prevMtime)) {
            // File modified
            _lastModified[path] = mtime;
            _enqueueDebouncedEvent(
              FileWatchEvent(
                  path: path,
                  eventType: FileEventType.modified,
                  timestamp: DateTime.now()),
            );
          }
        }
      }

      // Detect deletions: files in _lastModified but not in current scan
      final deleted = _lastModified.keys.where((p) {
        if (_isBlacklisted(p)) return false;
        return !currentPaths.contains(p);
      }).toList();

      for (final path in deleted) {
        _lastModified.remove(path);
        _enqueueDebouncedEvent(
          FileWatchEvent(
              path: path,
              eventType: FileEventType.deleted,
              timestamp: DateTime.now()),
        );
      }
    } catch (_) {
      // Skip on error; retry next poll
    }
  }

  // ============================================================
  // Debounce
  // ============================================================

  final List<FileWatchEvent> _pendingEvents = [];

  void _enqueueDebouncedEvent(FileWatchEvent event) {
    _pendingEvents.add(event);

    // Cancel existing timer for this specific path
    _debounceTimers[event.path]?.cancel();

    _debounceTimers[event.path] = Timer(debounceDelay, () {
      _flushDebouncedEvents();
    });
  }

  void _flushDebouncedEvents() {
    if (_pendingEvents.isEmpty || !_running) return;

    // Merge: for same path, keep only the latest event type
    // created + modified = created; modified + deleted = deleted
    final merged = <String, FileWatchEvent>{};
    for (final event in _pendingEvents) {
      final existing = merged[event.path];
      if (existing == null) {
        merged[event.path] = event;
      } else {
        // Precedence: deleted > created > modified
        if (event.eventType == FileEventType.deleted) {
          merged[event.path] = event;
        } else if (event.eventType == FileEventType.created &&
            existing.eventType == FileEventType.modified) {
          merged[event.path] = event;
        }
      }
    }

    final events = merged.values.toList();
    _pendingEvents.clear();

    if (events.isNotEmpty) {
      onChanged?.call(events);
    }
  }

  // ============================================================
  // Blacklist
  // ============================================================

  bool _isBlacklisted(String filePath) {
    final normalizedPath = filePath.replaceAll('\\', '/').toLowerCase();
    final segments = normalizedPath.split('/');

    for (final pattern in _blacklist) {
      final lowerPattern = pattern.toLowerCase();

      // Check path segments for exact directory name match
      for (final segment in segments) {
        if (segment == lowerPattern) return true;
      }

      // Check filename prefix patterns (e.g., ~$ , .tmp)
      final fileName = segments.last;
      if (fileName.startsWith(lowerPattern)) return true;
      if (fileName.endsWith(lowerPattern)) return true;
    }
    return false;
  }
}
