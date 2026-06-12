import 'dart:convert';

import 'package:test/test.dart';

/// Tests for clipboard sync message serialization and deduplication logic.
///
/// Since ClipboardSyncService requires a running signaling server and
/// platform channels, these tests focus on the data structures and
/// algorithms that can be validated in isolation.

void main() {
  group('ClipboardSyncService message serialization', () {
    test('register message has correct structure', () {
      final msg = {
        'type': 'register',
        'from': 'device-001',
        'payload': {
          'device_id': 'device-001',
          'device_name': 'Test Device',
          'platform': 'windows',
          'protocol_version': 1,
        },
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['type'], equals('register'));
      expect(decoded['from'], equals('device-001'));
      expect(decoded['payload']['device_id'], equals('device-001'));
      expect(decoded['payload']['device_name'], equals('Test Device'));
      expect(decoded['payload']['platform'], equals('windows'));
      expect(decoded['payload']['protocol_version'], equals(1));
    });

    test('clipboard message has correct structure', () {
      final msg = {
        'type': 'clipboard',
        'from': 'device-001',
        'payload': {
          'content_hash': 'abc123def456',
          'mime_type': 'text/plain',
          'text': 'Hello from LocalSend',
          'is_url': false,
          'timestamp': 1700000000000,
        },
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['type'], equals('clipboard'));
      expect(decoded['payload']['mime_type'], equals('text/plain'));
      expect(decoded['payload']['text'], equals('Hello from LocalSend'));
      expect(decoded['payload']['is_url'], isFalse);
    });

    test('clipboard message with URL sets is_url=true and url field', () {
      final msg = {
        'type': 'clipboard',
        'from': 'device-001',
        'payload': {
          'content_hash': 'urlhash123',
          'mime_type': 'text/plain',
          'text': 'https://github.com/localsend/localsend',
          'is_url': true,
          'url': 'https://github.com/localsend/localsend',
          'timestamp': 1700000000000,
        },
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['payload']['is_url'], isTrue);
      expect(
          decoded['payload']['url'],
          equals('https://github.com/localsend/localsend'));
    });

    test('ping message has correct structure', () {
      final msg = {
        'type': 'ping',
        'from': 'device-001',
        'timestamp': 1700000000000,
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['type'], equals('ping'));
      expect(decoded.containsKey('timestamp'), isTrue);
    });

    test('error message has correct structure', () {
      final msg = {
        'type': 'error',
        'from': 'server',
        'error': {
          'code': 1001,
          'message': 'Device not registered',
        },
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['type'], equals('error'));
      expect(decoded['error']['code'], equals(1001));
      expect(decoded['error']['message'], equals('Device not registered'));
    });

    test('device list message parses correctly', () {
      final msg = {
        'type': 'device_list',
        'from': 'server',
        'payload': {
          'devices': [
            {
              'device_id': 'dev-1',
              'device_name': 'Laptop',
              'online': true,
              'platform': 'windows',
            },
            {
              'device_id': 'dev-2',
              'device_name': 'Phone',
              'online': true,
              'platform': 'android',
            },
          ],
        },
      };

      final json = jsonEncode(msg);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final devices =
          (decoded['payload']['devices'] as List).cast<Map<String, dynamic>>();

      expect(devices.length, equals(2));
      expect(devices[0]['device_id'], equals('dev-1'));
      expect(devices[1]['device_name'], equals('Phone'));
    });
  });

  group('Clipboard deduplication logic', () {
    /// Simulate the hash-based dedup algorithm.
    String computeHash(String content) {
      // Simple test hash: just use content identity for test
      return 'hash_${content.hashCode}';
    }

    bool shouldSend(String content, String? lastHash) {
      final hash = computeHash(content);
      return hash != lastHash;
    }

    test('first content triggers send', () {
      expect(shouldSend('Hello', null), isTrue);
    });

    test('same content does not trigger send', () {
      final hash = computeHash('Hello');
      expect(shouldSend('Hello', hash), isFalse);
    });

    test('different content triggers send', () {
      final hash = computeHash('Hello');
      expect(shouldSend('World', hash), isTrue);
    });

    test('empty content should not trigger send', () {
      // Empty content check should be done before hash comparison
      bool shouldSendContent(String content, String? lastHash) {
        if (content.isEmpty) return false;
        return shouldSend(content, lastHash);
      }

      expect(shouldSendContent('', null), isFalse);
      expect(shouldSendContent('   ', null), isFalse); // whitespace only
    });
  });

  group('URL relay pattern matching', () {
    test('detects YouTube URLs', () {
      final urls = [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtube.com/shorts/abc123',
      ];
      final pattern = RegExp(r'youtube\.com/', caseSensitive: false);
      for (final url in urls) {
        expect(pattern.hasMatch(url), isTrue);
      }
    });

    test('detects Bilibili URLs', () {
      final urls = [
        'https://www.bilibili.com/video/BV1xx411c7mD',
        'https://b23.tv/abc123',
      ];
      final pattern =
          RegExp(r'bilibili\.com/|b23\.tv/', caseSensitive: false);
      for (final url in urls) {
        expect(pattern.hasMatch(url), isTrue);
      }
    });

    test('detects Douyin URLs', () {
      final urls = [
        'https://www.douyin.com/video/123456',
        'https://v.douyin.com/abc123/',
      ];
      final pattern =
          RegExp(r'douyin\.com/|v\.douyin\.com/', caseSensitive: false);
      for (final url in urls) {
        expect(pattern.hasMatch(url), isTrue);
      }
    });

    test('detects GitHub URLs', () {
      final urls = [
        'https://github.com/localsend/localsend',
        'https://www.github.com/flutter/flutter',
      ];
      final pattern = RegExp(r'github\.com/', caseSensitive: false);
      for (final url in urls) {
        expect(pattern.hasMatch(url), isTrue);
      }
    });

    test('generic URL detection', () {
      final genericPattern =
          RegExp(r'^https?://[^\s/$.?#].[^\s]*$', caseSensitive: false);

      expect(genericPattern.hasMatch('https://example.com'), isTrue);
      expect(genericPattern.hasMatch('http://192.168.1.1:8080/path'), isTrue);
      expect(genericPattern.hasMatch('not a url'), isFalse);
      expect(genericPattern.hasMatch('ftp://example.com'), isFalse);
    });

    test('WeChat article URLs detected', () {
      final urls = [
        'https://mp.weixin.qq.com/s/abc123',
        'http://mp.weixin.qq.com/s?__biz=xxx',
      ];
      final pattern = RegExp(r'mp\.weixin\.qq\.com/', caseSensitive: false);
      for (final url in urls) {
        expect(pattern.hasMatch(url), isTrue);
      }
    });
  });
}
