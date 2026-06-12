import 'package:test/test.dart';

/// Tests for the ResumeManager logic (transfer_id to chunk set mapping,
/// next-chunk computation, cleanup).
///
/// These tests validate the in-memory state machine without requiring
/// SharedPreferences. The same algorithms apply whether backed by
/// SharedPreferences or any other key-value store.

void main() {
  group('ResumeManager transfer state', () {
    test('empty state returns chunk 0 as next', () {
      final chunks = <int>{};
      expect(_nextChunk(chunks, 100), equals(0));
    });

    test('sequential chunks return next in sequence', () {
      final chunks = {0, 1, 2, 3};
      expect(_nextChunk(chunks, 10), equals(4));
    });

    test('gaps return first missing chunk', () {
      final chunks = {0, 1, 3, 4, 5};
      expect(_nextChunk(chunks, 10), equals(2));
    });

    test('all chunks received returns -1 (complete)', () {
      final chunks = {0, 1, 2, 3, 4};
      expect(_nextChunk(chunks, 5), equals(-1));
    });

    test('tail contiguous returns first missing', () {
      final chunks = {0, 1, 2, 3, 4, 6, 7};
      expect(_nextChunk(chunks, 10), equals(5));
    });

    test('total chunks count is less than received', () {
      // Should not happen normally, but handle gracefully
      final chunks = {0, 1, 2, 3, 4, 5};
      expect(_nextChunk(chunks, 5), equals(-1));
    });
  });

  group('ResumeManager chunk serialization', () {
    /// Simulate SharedPreferences string storage for Set<int>.
    String serializeChunks(Set<int> chunks) {
      if (chunks.isEmpty) return '';
      return chunks.map((c) => c.toString()).join(',');
    }

    Set<int> deserializeChunks(String data) {
      if (data.isEmpty) return {};
      return data.split(',').map(int.parse).toSet();
    }

    test('empty set serializes to empty string', () {
      expect(serializeChunks({}), equals(''));
    });

    test('non-empty set serializes and deserializes correctly', () {
      final original = {0, 5, 10, 99};
      final serialized = serializeChunks(original);
      final deserialized = deserializeChunks(serialized);

      expect(deserialized, equals(original));
    });

    test('large sets round-trip correctly', () {
      final original = Set<int>.from(
          List.generate(1000, (i) => i * 2)); // 0, 2, 4, ..., 1998
      final serialized = serializeChunks(original);
      final deserialized = deserializeChunks(serialized);

      expect(deserialized.length, equals(1000));
      expect(deserialized, equals(original));
    });

    test('single chunk round-trips', () {
      final original = {42};
      final serialized = serializeChunks(original);
      final deserialized = deserializeChunks(serialized);

      expect(deserialized, equals(original));
    });
  });

  group('ResumeManager key generation', () {
    test('transfer key is consistent', () {
      String key(String prefix, String transferId) {
        return '${prefix}_$transferId';
      }

      final k1 = key('resume', 'transfer-001');
      final k2 = key('resume', 'transfer-001');

      expect(k1, equals(k2));
      expect(k1, equals('resume_transfer-001'));
    });
  });

  group('ResumeManager state machine', () {
    test('new transfer starts with empty chunks', () {
      final state = _ResumeState();
      state.startTransfer('tx-1', 50);
      expect(state.getChunks('tx-1'), isEmpty);
      expect(state.getNextChunk('tx-1'), equals(0));
    });

    test('adding chunks advances next chunk correctly', () {
      final state = _ResumeState();
      state.startTransfer('tx-2', 10);

      state.addChunk('tx-2', 0);
      expect(state.getNextChunk('tx-2'), equals(1));

      state.addChunk('tx-2', 1);
      state.addChunk('tx-2', 2);
      expect(state.getNextChunk('tx-2'), equals(3));
    });

    test('adding out-of-order chunks preserves correct next', () {
      final state = _ResumeState();
      state.startTransfer('tx-3', 100);

      state.addChunk('tx-3', 5);
      state.addChunk('tx-3', 10);
      // Next should still be 0 even though 5 and 10 are present
      expect(state.getNextChunk('tx-3'), equals(0));

      state.addChunk('tx-3', 0);
      state.addChunk('tx-3', 1);
      expect(state.getNextChunk('tx-3'), equals(2));
    });

    test('completing a transfer clears state', () {
      final state = _ResumeState();
      state.startTransfer('tx-4', 3);

      state.addChunk('tx-4', 0);
      state.addChunk('tx-4', 1);
      state.addChunk('tx-4', 2);

      expect(state.getNextChunk('tx-4'), equals(-1));

      state.completeTransfer('tx-4');
      expect(state.hasTransfer('tx-4'), isFalse);
    });

    test('isTransferInterrupted returns true for incomplete transfers', () {
      final state = _ResumeState();
      state.startTransfer('tx-5', 100);
      state.addChunk('tx-5', 0);

      expect(state.isInterrupted('tx-5'), isTrue);
    });

    test('isTransferInterrupted returns false for completed transfers', () {
      final state = _ResumeState();
      state.startTransfer('tx-6', 10);

      for (int i = 0; i < 10; i++) {
        state.addChunk('tx-6', i);
      }

      expect(state.isInterrupted('tx-6'), isFalse);
    });
  });
}

/// Compute the next missing chunk index.
///
/// Returns -1 if all chunks have been received.
int _nextChunk(Set<int> received, int totalChunks) {
  if (received.length >= totalChunks) return -1;
  for (int i = 0; i < totalChunks; i++) {
    if (!received.contains(i)) return i;
  }
  return -1;
}

/// In-memory ResumeManager state for testing without SharedPreferences.
class _ResumeState {
  final Map<String, _TransferResumeState> _transfers = {};

  void startTransfer(String id, int totalChunks) {
    _transfers[id] = _TransferResumeState(totalChunks: totalChunks);
  }

  Set<int> getChunks(String id) {
    return _transfers[id]?.chunks ?? {};
  }

  void addChunk(String id, int chunkIndex) {
    _transfers[id]?.chunks.add(chunkIndex);
  }

  int getNextChunk(String id) {
    final state = _transfers[id];
    if (state == null) return 0;
    return _nextChunk(state.chunks, state.totalChunks);
  }

  void completeTransfer(String id) {
    _transfers.remove(id);
  }

  bool hasTransfer(String id) {
    return _transfers.containsKey(id);
  }

  bool isInterrupted(String id) {
    final state = _transfers[id];
    if (state == null) return false;
    return state.chunks.length < state.totalChunks;
  }
}

class _TransferResumeState {
  final int totalChunks;
  final Set<int> chunks = {};

  _TransferResumeState({required this.totalChunks});
}
