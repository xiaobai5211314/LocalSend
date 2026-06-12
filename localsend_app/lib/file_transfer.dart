import 'dart:io';

class FileTransferService {
  HttpServer? _server;
  String? _localIp;
  int _port = 0;
  String? _token;
  final Map<String, _ServedFile> _servedFiles = {};

  int get port => _port;
  String? get localIp => _localIp;

  Future<void> _ensureServer() async {
    if (_server != null) return;
    _token = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    _localIp = await _getLocalIp();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _port = _server!.port;

    _server!.listen((request) async {
      final uri = request.uri;
      if (uri.queryParameters['token'] != _token) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }

      if (uri.path.startsWith('/file/') && request.method == 'GET') {
        final fileId = uri.path.substring('/file/'.length);
        final info = _servedFiles[fileId];
        if (info == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final file = File(info.path);
        if (!await file.exists()) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.contentLength = await file.length();
        await file.openRead().pipe(request.response);
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  Future<String> serveFile(String filePath) async {
    await _ensureServer();
    final fileId = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    _servedFiles[fileId] = _ServedFile(path: filePath);
    return 'http://$_localIp:$_port/file/$fileId?token=$_token';
  }

  static Future<void> downloadFile(String url, String savePath) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final file = File(savePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      await response.pipe(sink);
    } finally {
      client.close();
    }
  }

  static Future<String?> _getLocalIp() async {
    for (final interface in await NetworkInterface.list()) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return null;
  }

  void stop() {
    _server?.close();
    _server = null;
    _servedFiles.clear();
  }

  void dispose() {
    stop();
  }
}

class _ServedFile {
  final String path;
  _ServedFile({required this.path});
}
