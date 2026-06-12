import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

class FileTransferService {
  final String serverBaseUrl;

  FileTransferService({required this.serverBaseUrl});

  /// Upload file to server, return {fileId, downloadUrl}
  Future<Map<String, dynamic>> uploadFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('File not found: $filePath');

    final request = http.StreamedRequest('POST', Uri.parse('$serverBaseUrl/api/upload'));
    final fileLength = await file.length();
    request.contentLength = fileLength;
    file.openRead().listen(
      (chunk) => request.sink.add(chunk),
      onDone: () => request.sink.close(),
      onError: (e) => request.sink.addError(e),
    );

    final streamedResponse = await request.send().timeout(Duration(minutes: 10));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final fileId = data['file_id'] as String;
    final size = data['size'] as int;

    return {
      'file_id': fileId,
      'download_url': '$serverBaseUrl/api/files/$fileId',
      'size': size,
    };
  }

  /// Download file from URL to savePath
  static Future<void> downloadFile(String url, String savePath) async {
    final client = HttpClient();
    client.connectionTimeout = Duration(minutes: 5);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(Duration(minutes: 10));
      final file = File(savePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      await response.pipe(sink);
    } finally {
      client.close();
    }
  }

  /// Check server health
  Future<bool> checkHealth() async {
    try {
      final response = await http.get(
        Uri.parse('$serverBaseUrl/health'),
      ).timeout(Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void dispose() {}
}
