import 'dart:io';

import 'package:test/test.dart';

/// Tests for the folder sync conflict resolution strategy.
///
/// Validates the conflict handling algorithm: when a file exists
/// at the target path, the newer file (by modification time) wins,
/// and the older file is renamed to .conflict.{timestamp}.

void main() {
  group('FolderSyncService conflict resolution', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('localsend_sync_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Simulate the conflict resolution algorithm.
    Future<ConflictResult> resolveConflict(
      String targetPath,
      String incomingPath,
      DateTime incomingModTime,
    ) async {
      final targetFile = File(targetPath);
      final incomingFile = File(incomingPath);

      if (!await targetFile.exists()) {
        // No conflict: simply copy
        await incomingFile.copy(targetPath);
        return ConflictResult.noConflict;
      }

      final targetModTime = await targetFile.lastModified();

      if (incomingModTime.isAfter(targetModTime)) {
        // Incoming file is newer: rename old to .conflict.{timestamp}
        final conflictPath =
            '$targetPath.conflict.${targetModTime.millisecondsSinceEpoch}';
        await targetFile.rename(conflictPath);
        await incomingFile.copy(targetPath);
        return ConflictResult.incomingWon(conflictPath);
      } else {
        // Target is newer or same: keep target, save incoming as conflict
        final conflictPath =
            '$targetPath.conflict.${incomingModTime.millisecondsSinceEpoch}';
        await incomingFile.copy(conflictPath);
        return ConflictResult.targetWon(conflictPath);
      }
    }

    test('no conflict when target does not exist', () async {
      final targetPath = '${tempDir.path}/new_file.txt';
      final incoming = File('${tempDir.path}/incoming.txt');
      await incoming.writeAsString('incoming content');

      final result = await resolveConflict(
          targetPath, incoming.path, DateTime(2025, 1, 1));

      expect(result.type, equals(ConflictType.noConflict));
      expect(File(targetPath).existsSync(), isTrue);
      expect(File(targetPath).readAsStringSync(),
          equals('incoming content'));
    });

    test('incoming file wins when newer', () async {
      final targetPath = '${tempDir.path}/doc.txt';
      final incoming = File('${tempDir.path}/incoming_doc.txt');

      // Create target with older timestamp
      await File(targetPath).writeAsString('old content');
      await File(targetPath)
          .setLastModified(DateTime(2024, 1, 1, 0, 0, 0));

      // Create incoming with newer content
      await incoming.writeAsString('new content');

      final result = await resolveConflict(
          targetPath, incoming.path, DateTime(2025, 6, 1));

      expect(result.type, equals(ConflictType.incomingWon));
      expect(File(targetPath).readAsStringSync(),
          equals('new content'));
      expect(result.conflictPath, isNotNull);
      expect(File(result.conflictPath!).existsSync(), isTrue);
      expect(File(result.conflictPath!).readAsStringSync(),
          equals('old content'));
      expect(result.conflictPath, contains('.conflict.'));
    });

    test('target file wins when newer', () async {
      final targetPath = '${tempDir.path}/data.txt';
      final incoming = File('${tempDir.path}/incoming_data.txt');

      // Create target with newer timestamp
      await File(targetPath).writeAsString('new content');
      await File(targetPath)
          .setLastModified(DateTime(2025, 6, 1, 0, 0, 0));

      // Create incoming with older content
      await incoming.writeAsString('old content');

      final result = await resolveConflict(
          targetPath, incoming.path, DateTime(2024, 1, 1));

      expect(result.type, equals(ConflictType.targetWon));
      expect(File(targetPath).readAsStringSync(),
          equals('new content'));
      expect(result.conflictPath, isNotNull);
      expect(File(result.conflictPath!).existsSync(), isTrue);
      expect(File(result.conflictPath!).readAsStringSync(),
          equals('old content'));
    });

    test('conflict file naming follows .conflict.{timestamp} pattern', () async {
      final targetPath = '${tempDir.path}/settings.json';
      final incoming = File('${tempDir.path}/incoming_settings.json');

      await File(targetPath).writeAsString('{"version": 1}');
      await File(targetPath)
          .setLastModified(DateTime(2024, 3, 15, 10, 0, 0));
      await incoming.writeAsString('{"version": 2}');

      final result = await resolveConflict(
          targetPath, incoming.path, DateTime(2025, 1, 1, 12, 0, 0));

      expect(result.conflictPath, isNotNull);

      // Pattern: original.conflict.{timestamp}
      final baseFileName = 'settings.json';
      expect(result.conflictPath, contains(baseFileName));
      expect(result.conflictPath, contains('.conflict.'));

      // Timestamp should be numeric
      final conflictFile = File(result.conflictPath!);
      final parts = conflictFile.uri.pathSegments.last.split('.');
      final timestampPart = parts.last;
      expect(int.tryParse(timestampPart), isNotNull);
    });
  });

  group('ConflictResult format', () {
    test('noConflict result has correct fields', () {
      final result = ConflictResult.noConflict;
      expect(result.type, equals(ConflictType.noConflict));
      expect(result.conflictPath, isNull);
    });

    test('incomingWon result has correct fields', () {
      final result = ConflictResult.incomingWon('/path/old_version.txt');
      expect(result.type, equals(ConflictType.incomingWon));
      expect(result.conflictPath, equals('/path/old_version.txt'));
    });

    test('targetWon result has correct fields', () {
      final result = ConflictResult.targetWon('/path/incoming_version.txt');
      expect(result.type, equals(ConflictType.targetWon));
      expect(result.conflictPath, equals('/path/incoming_version.txt'));
    });
  });
}

// ============================================================
// Conflict Resolution Types
// ============================================================

/// Result of conflict resolution.
class ConflictResult {
  final ConflictType type;
  final String? conflictPath;

  ConflictResult._({required this.type, this.conflictPath});

  static final ConflictResult noConflict =
      ConflictResult._(type: ConflictType.noConflict);

  static ConflictResult incomingWon(String oldPath) => ConflictResult._(
        type: ConflictType.incomingWon,
        conflictPath: oldPath,
      );

  static ConflictResult targetWon(String incomingPath) => ConflictResult._(
        type: ConflictType.targetWon,
        conflictPath: incomingPath,
      );
}

/// Possible outcomes of conflict resolution.
enum ConflictType {
  /// No file existed at the target path.
  noConflict,

  /// The incoming file was newer and replaced the target.
  /// The old target was renamed to [conflictPath].
  incomingWon,

  /// The target file was newer and was kept.
  /// The incoming file was saved to [conflictPath].
  targetWon,
}
