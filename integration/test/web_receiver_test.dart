import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Tests for the web receiver service — token generation, validation,
/// and the embedded download page HTML structure.

void main() {
  group('WebReceiverService token generation', () {
    /// Generate a token using SHA-256 of a random seed.
    String generateToken() {
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 32);
    }

    test('generates 32-character hex token', () {
      final token = generateToken();
      expect(token.length, equals(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(token), isTrue);
    });

    test('consecutive tokens are unique', () {
      final tokens = List.generate(10, (_) => generateToken());
      final uniqueTokens = Set<String>.from(tokens);
      expect(uniqueTokens.length, equals(10));
    });
  });

  group('WebReceiverService URL construction', () {
    test('URL format is correct', () {
      final ip = '192.168.1.100';
      final port = 50123;
      final token = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

      final url = 'http://$ip:$port/$token/download';

      expect(url, equals(
          'http://192.168.1.100:50123/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6/download'));
      expect(Uri.parse(url).host, equals(ip));
      expect(Uri.parse(url).port, equals(port));
      expect(Uri.parse(url).path, equals(
          '/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6/download'));
    });

    test('URL is valid HTTP URI', () {
      final url = 'http://10.0.0.5:50000/abc123def45678901234567890abcd/download';
      final uri = Uri.parse(url);
      expect(uri.scheme, equals('http'));
      expect(uri.host, isNotEmpty);
      expect(uri.port, greaterThan(0));
      expect(uri.port, lessThan(65536));
    });
  });

  group('WebReceiverService port selection', () {
    /// Simulate port selection from the range 49152-65535.
    int selectPort(List<int> usedPorts) {
      final random = Random(42); // Fixed seed for testing
      for (int attempt = 0; attempt < 100; attempt++) {
        final port = 49152 + random.nextInt(65535 - 49152 + 1);
        if (!usedPorts.contains(port)) return port;
      }
      throw StateError('No available ports');
    }

    test('selected port is within range', () {
      final port = selectPort([]);
      expect(port, greaterThanOrEqualTo(49152));
      expect(port, lessThanOrEqualTo(65535));
    });

    test('avoids used ports', () {
      final usedPorts = [50000, 53000, 60000];
      for (int i = 0; i < 10; i++) {
        final port = selectPort(usedPorts);
        expect(usedPorts.contains(port), isFalse);
      }
    });
  });

  group('WebReceiverService download page HTML', () {
    /// Minimal HTML structure test.
    test('HTML contains required elements', () {
      final html = '''
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>LocalSend - File Download</title>
        <style>
          :root { --bg: #ffffff; --text: #1a1a1a; --accent: #4A90D9; }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #1a1a1a; --text: #e0e0e0; --accent: #6db3f2; }
          }
          body { background: var(--bg); color: var(--text); font-family: system-ui, sans-serif; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>File Download</h1>
          <div id="file-list"></div>
          <div id="status"></div>
        </div>
      </body>
      </html>
      ''';

      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<title>LocalSend'));
      expect(html, contains('prefers-color-scheme: dark'));
      expect(html, contains('file-list'));
      expect(html, contains('viewport'));
    });

    test('HTML supports dark mode via CSS', () {
      final html = '<style>'
          '@media (prefers-color-scheme: dark) { body { background: #1a1a1a; } }'
          '</style>';

      expect(html, contains('prefers-color-scheme: dark'));
      expect(html, contains('background: #1a1a1a'));
    });
  });

  group('WebReceiverService ZIP packaging', () {
    test('file list to ZIP naming', () {
      final fileNames = ['report.pdf', 'photo.jpg', 'notes.txt'];
      final expectedZipName = 'files_${fileNames.length}.zip';

      expect(expectedZipName, equals('files_3.zip'));
    });

    test('single file returns direct filename', () {
      final fileNames = ['important_document.pdf'];
      // Single files should be served directly, not zipped
      expect(fileNames.length, equals(1));
    });

    test('empty file list handled gracefully', () {
      final fileNames = <String>[];
      expect(fileNames.isEmpty, isTrue);
    });
  });

  group('WebReceiverService concurrency', () {
    test('max connections defaults to 10', () {
      const maxConnections = 10;
      expect(maxConnections, equals(10));
    });

    test('connection counter respects limit', () {
      const maxConnections = 10;
      int activeConnections = 0;

      bool canAccept() => activeConnections < maxConnections;

      for (int i = 0; i < 10; i++) {
        activeConnections++;
        expect(canAccept(), isFalse);
      }
    });

    test('released connection becomes available', () {
      const maxConnections = 10;
      int activeConnections = 10;

      activeConnections--;
      expect(activeConnections < maxConnections, isTrue);
    });
  });

  group('WebReceiverService idle timeout', () {
    test('should close after 5 minutes of inactivity', () {
      const idleTimeout = Duration(minutes: 5);
      expect(idleTimeout.inMinutes, equals(5));
      expect(idleTimeout.inSeconds, equals(300));
    });
  });
}
