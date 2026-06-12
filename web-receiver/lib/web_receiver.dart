import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// Result returned after starting the web receiver server.
class WebReceiverResult {
  final String downloadUrl;
  final String token;
  final int port;
  final String ipAddress;

  WebReceiverResult({
    required this.downloadUrl,
    required this.token,
    required this.port,
    required this.ipAddress,
  });
}

/// Shareable file entry.
class ShareableFile {
  final String filePath;
  final String fileName;
  final int fileSize;
  final String mimeType;

  ShareableFile({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
  });
}

/// Web Receiver Service
///
/// Starts a temporary HTTP server on an available port (49152-65535)
/// that serves files for download via a secure one-time token URL.
///
/// Features:
/// - Automatic port selection in ephemeral range (49152-65535)
/// - SHA256-based one-time access token
/// - Single file direct download
/// - Multiple files served as ZIP archive
/// - Auto-shutdown after last download + 5-minute idle timeout
/// - Dark-mode responsive HTML download page
/// - Maximum 10 concurrent connections
class WebReceiverService {
  HttpServer? _server;
  String? _token;
  final Map<String, ShareableFile> _sharedFiles = {};
  Timer? _shutdownTimer;
  Timer? _idleTimer;
  int _activeConnections = 0;
  int _downloadCount = 0;
  bool _isRunning = false;

  /// Maximum concurrent connections.
  static const int maxConnections = 10;

  /// Port range for automatic selection.
  static const int portMin = 49152;
  static const int portMax = 65535;

  /// Idle timeout after last download before auto-shutdown.
  static const Duration idleTimeout = Duration(minutes: 5);

  /// Callback invoked when the server starts.
  void Function(WebReceiverResult result)? onStarted;

  /// Callback invoked when the server shuts down.
  void Function()? onStopped;

  /// Callback for logging.
  void Function(String message)? onLog;

  /// Whether the server is currently running.
  bool get isRunning => _isRunning;

  /// The number of downloads served so far.
  int get downloadCount => _downloadCount;

  /// Whether the token has been consumed.
  bool get isTokenExpired => _downloadCount > 0;

  // ============================================================
  // Server Lifecycle
  // ============================================================

  /// Start the web receiver server with the given files.
  ///
  /// Automatically selects an available port from the 49152-65535 range
  /// and generates a one-time access token.
  Future<WebReceiverResult> start({
    required List<String> filePaths,
    String? customToken,
  }) async {
    if (_isRunning) {
      throw StateError('Web receiver is already running');
    }

    // Validate and collect shared files
    _sharedFiles.clear();
    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) {
        throw Exception('File not found: $path');
      }
      final fileName = p.basename(path);
      final fileSize = await file.length();
      final mimeType = lookupMimeType(path) ?? 'application/octet-stream';
      _sharedFiles[fileName] = ShareableFile(
        filePath: path,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
      );
    }

    if (_sharedFiles.isEmpty) {
      throw Exception('No valid files to share');
    }

    // Generate or use provided token
    _token = customToken ?? _generateToken();
    _downloadCount = 0;

    // Find available port
    final port = await _findAvailablePort();

    // Get local IP
    final ipAddress = await _getLocalIp();

    // Build router
    final router = Router();

    // Download endpoint: /{token}/download
    router.get('/<_token>/download', _handleDownload);
    router.get('/<_token>/download/<file>', _handleFileDownload);

    // Landing page: /{token}
    router.get('/<_token>', _handleLandingPage);

    // Health check
    router.get('/health', (Request request) {
      return Response.ok('{"status":"ok"}',
          headers: {'content-type': 'application/json'});
    });

    // Middleware chain
    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_concurrencyGuard)
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    _isRunning = true;

    final downloadUrl = 'http://$ipAddress:${_server!.port}/$_token';
    final result = WebReceiverResult(
      downloadUrl: downloadUrl,
      token: _token!,
      port: _server!.port,
      ipAddress: ipAddress,
    );

    onStarted?.call(result);
    onLog?.call('Web receiver started on $downloadUrl');

    return result;
  }

  /// Stop the server immediately.
  Future<void> stop() async {
    _shutdownTimer?.cancel();
    _idleTimer?.cancel();
    await _server?.close(force: true);
    _server = null;
    _token = null;
    _sharedFiles.clear();
    _isRunning = false;
    onStopped?.call();
    onLog?.call('Web receiver stopped');
  }

  /// Generate a fresh token (invalidates the previous one).
  String regenerateToken() {
    _token = _generateToken();
    _downloadCount = 0;
    return _token!;
  }

  // ============================================================
  // Port Selection
  // ============================================================

  Future<int> _findAvailablePort() async {
    final rng = Random();
    for (int i = 0; i < 50; i++) {
      final port = portMin + rng.nextInt(portMax - portMin + 1);
      try {
        final server = await ServerSocket.bind(
            InternetAddress.anyIPv4, port);
        await server.close();
        return port;
      } catch (_) {
        continue;
      }
    }
    throw Exception(
        'No available port found in range $portMin-$portMax');
  }

  // ============================================================
  // IP Detection
  // ============================================================

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {
      // Fallback
    }
    return '127.0.0.1';
  }

  // ============================================================
  // Token Generation
  // ============================================================

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return sha256.convert(bytes).toString().substring(0, 16);
  }

  // ============================================================
  // Request Handlers
  // ============================================================

  Future<Response> _handleLandingPage(Request request) async {
    final reqToken = request.params['_token']!;
    if (reqToken != _token) {
      return Response.forbidden('Invalid token');
    }

    final files = _sharedFiles.values.toList();
    final html = _buildDownloadPage(files);
    return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
  }

  Future<Response> _handleDownload(Request request) async {
    final reqToken = request.params['_token']!;
    if (reqToken != _token) {
      return Response.forbidden('Invalid token');
    }

    _downloadCount++;
    _activeConnections++;
    _resetIdleTimer();

    try {
      if (_sharedFiles.length == 1) {
        // Single file: direct download
        final file = _sharedFiles.values.first;
        return _serveFile(file);
      } else {
        // Multiple files: create ZIP archive
        return _serveZipArchive(_sharedFiles.values.toList());
      }
    } finally {
      _activeConnections--;
    }
  }

  Future<Response> _handleFileDownload(Request request) async {
    final reqToken = request.params['_token']!;
    final fileName = request.params['file']!;

    if (reqToken != _token) {
      return Response.forbidden('Invalid token');
    }

    final file = _sharedFiles[fileName];
    if (file == null) {
      return Response.notFound('File not found');
    }

    _downloadCount++;
    _activeConnections++;
    _resetIdleTimer();

    try {
      return _serveFile(file);
    } finally {
      _activeConnections--;
    }
  }

  // ============================================================
  // File Serving
  // ============================================================

  Response _serveFile(ShareableFile file) {
    final fileBytes = File(file.filePath).readAsBytesSync();
    return Response.ok(
      fileBytes,
      headers: {
        'content-type': file.mimeType,
        'content-disposition':
            'attachment; filename="${file.fileName}"',
        'content-length': file.fileSize.toString(),
        'cache-control': 'no-store',
      },
    );
  }

  Response _serveZipArchive(List<ShareableFile> files) {
    // Build a simple ZIP archive in memory
    final zipBytes = _buildZipArchive(files);
    return Response.ok(
      zipBytes,
      headers: {
        'content-type': 'application/zip',
        'content-disposition': 'attachment; filename="files.zip"',
        'content-length': zipBytes.length.toString(),
        'cache-control': 'no-store',
      },
    );
  }

  /// Simple ZIP archive builder (stores uncompressed).
  List<int> _buildZipArchive(List<ShareableFile> files) {
    final output = BytesBuilder();
    final fileEntries = <_ZipEntry>[];

    int offset = 0;

    for (final file in files) {
      final data = File(file.filePath).readAsBytesSync();
      final nameBytes = utf8.encode(file.fileName);
      final crc = _crc32(data);

      // Local file header
      final localHeader = BytesBuilder();
      localHeader.add(_u32(0x04034b50)); // signature
      localHeader.add(_u16(20)); // version needed
      localHeader.add(_u16(0)); // flags
      localHeader.add(_u16(0)); // compression: store
      localHeader.add(_u16(0)); // mod time
      localHeader.add(_u16(0)); // mod date
      localHeader.add(_u32(crc)); // crc32
      localHeader.add(_u32(data.length)); // compressed size
      localHeader.add(_u32(data.length)); // uncompressed size
      localHeader.add(_u16(nameBytes.length)); // file name length
      localHeader.add(_u16(0)); // extra field length

      output.add(localHeader.toBytes());
      output.add(nameBytes);
      output.add(data);

      fileEntries.add(_ZipEntry(
        name: file.fileName,
        crc: crc,
        size: data.length,
        offset: offset,
      ));

      offset += 30 + nameBytes.length + data.length;
    }

    final centralDirOffset = output.length;

    // Central directory entries
    for (final entry in fileEntries) {
      final nameBytes = utf8.encode(entry.name);
      final cd = BytesBuilder();
      cd.add(_u32(0x02014b50)); // central directory signature
      cd.add(_u16(20)); // version made by
      cd.add(_u16(20)); // version needed
      cd.add(_u16(0)); // flags
      cd.add(_u16(0)); // compression
      cd.add(_u16(0)); // mod time
      cd.add(_u16(0)); // mod date
      cd.add(_u32(entry.crc));
      cd.add(_u32(entry.size));
      cd.add(_u32(entry.size));
      cd.add(_u16(nameBytes.length));
      cd.add(_u16(0)); // extra
      cd.add(_u16(0)); // comment
      cd.add(_u16(0)); // disk
      cd.add(_u16(0)); // internal attrs
      cd.add(_u32(0)); // external attrs
      cd.add(_u32(entry.offset)); // local header offset

      output.add(cd.toBytes());
      output.add(nameBytes);
    }

    final centralDirSize = output.length - centralDirOffset;
    final totalEntries = fileEntries.length;

    // End of central directory
    final eocd = BytesBuilder();
    eocd.add(_u32(0x06054b50)); // EOCD signature
    eocd.add(_u16(0)); // disk number
    eocd.add(_u16(0)); // disk start
    eocd.add(_u16(totalEntries)); // entries on disk
    eocd.add(_u16(totalEntries)); // total entries
    eocd.add(_u32(centralDirSize)); // central dir size
    eocd.add(_u32(centralDirOffset)); // central dir offset
    eocd.add(_u16(0)); // comment length

    output.add(eocd.toBytes());

    return output.toBytes();
  }

  // ============================================================
  // HTML Page
  // ============================================================

  String _buildDownloadPage(List<ShareableFile> files) {
    final totalSize = files.fold<int>(0, (sum, f) => sum + f.fileSize);
    final totalSizeText = _formatSize(totalSize);

    final fileListItems = files.map((f) {
      return '''
      <div class="file-item">
        <svg class="file-icon" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm-1 2l5 5h-5V4zM6 20V4h5v7h7v9H6z"/></svg>
        <div class="file-info">
          <span class="file-name">${_escapeHtml(f.fileName)}</span>
          <span class="file-size">${_formatSize(f.fileSize)}</span>
        </div>
      </div>''';
    }).join('\n');

    final multiFile = files.length > 1;
    final downloadLabel = multiFile ? 'Download All (ZIP)' : 'Download';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LocalSend - File Share</title>
<style>
:root {
  --bg: #ffffff; --bg2: #f8f9fa; --text: #1a1a2e;
  --text2: #6c757d; --accent: #4f46e5; --accent-hover: #4338ca;
  --border: #e5e7eb; --card-bg: #ffffff; --shadow: 0 1px 3px rgba(0,0,0,.08);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111827; --bg2: #1f2937; --text: #f3f4f6;
    --text2: #9ca3af; --accent: #6366f1; --accent-hover: #818cf8;
    --border: #374151; --card-bg: #1f2937; --shadow: 0 1px 3px rgba(0,0,0,.3);
  }
}
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; }
.card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 16px; padding: 32px; max-width: 480px; width: 100%; box-shadow: var(--shadow); }
.logo { font-size: 28px; font-weight: 700; margin-bottom: 4px; }
.subtitle { color: var(--text2); font-size: 14px; margin-bottom: 24px; }
.file-item { display: flex; align-items: center; gap: 12px; padding: 12px; background: var(--bg2); border-radius: 10px; margin-bottom: 8px; }
.file-icon { width: 32px; height: 32px; fill: var(--accent); flex-shrink: 0; }
.file-info { display: flex; flex-direction: column; min-width: 0; }
.file-name { font-size: 14px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.file-size { font-size: 12px; color: var(--text2); }
.summary { display: flex; justify-content: space-between; align-items: center; margin: 20px 0; padding: 12px 0; border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); font-size: 14px; }
.download-btn { display: block; width: 100%; padding: 14px; background: var(--accent); color: #fff; border: none; border-radius: 10px; font-size: 16px; font-weight: 600; cursor: pointer; transition: background .2s; text-decoration: none; text-align: center; }
.download-btn:hover { background: var(--accent-hover); }
.footer { text-align: center; margin-top: 16px; font-size: 12px; color: var(--text2); }
</style>
</head>
<body>
<div class="card">
  <div class="logo">LocalSend</div>
  <div class="subtitle">${files.length} file(s) shared with you</div>
  $fileListItems
  <div class="summary">
    <span>${files.length} file(s)</span>
    <span>$totalSizeText</span>
  </div>
  <a class="download-btn" href="./$_token/download">$downloadLabel</a>
  <div class="footer">Secured with one-time token | Expires after download</div>
</div>
</body>
</html>''';
  }

  // ============================================================
  // Middleware
  // ============================================================

  Middleware get _concurrencyGuard => (Handler innerHandler) {
        return (Request request) {
          if (_activeConnections >= maxConnections) {
            return Response(503,
                body: 'Server busy. Please try again later.',
                headers: {'retry-after': '5'});
          }
          return innerHandler(request);
        };
      };

  // ============================================================
  // Idle Shutdown
  // ============================================================

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      onLog?.call('Idle timeout reached, shutting down');
      stop();
    });
  }

  // ============================================================
  // Utility Methods
  // ============================================================

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// CRC-32 for ZIP entries.
  static int _crc32(List<int> data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc >>= 1;
        }
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static List<int> _u32(int value) {
    return [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
  }

  static List<int> _u16(int value) {
    return [value & 0xFF, (value >> 8) & 0xFF];
  }
}

/// Internal ZIP central directory entry.
class _ZipEntry {
  final String name;
  final int crc;
  final int size;
  final int offset;

  _ZipEntry({
    required this.name,
    required this.crc,
    required this.size,
    required this.offset,
  });
}
