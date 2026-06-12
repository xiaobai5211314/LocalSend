import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WebReceiverService {
  HttpServer? _server;
  String? _token;
  int _port = 0;
  String? _localIp;

  final _transferController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get transferStream => _transferController.stream;

  String? get token => _token;
  int get port => _port;
  String? get localIp => _localIp;
  String get url => 'http://$_localIp:$_port?token=$_token';

  Future<void> start() async {
    _token = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    _localIp = await _getLocalIp();

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _port = _server!.port;

    _server!.listen((request) async {
      final uri = request.uri;
      if (uri.queryParameters['token'] != _token) {
        request.response.statusCode = 403;
        request.response.write('Unauthorized');
        await request.response.close();
        return;
      }

      if (uri.path == '/') {
        final html = _buildHtml();
        request.response.headers.contentType = ContentType.html;
        request.response.write(html);
        await request.response.close();
      } else if (uri.path == '/upload' && request.method == 'POST') {
        final boundary = request.headers.contentType?.parameters['boundary'];
        if (boundary != null) {
          final data = await request.cast<List<int>>().fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
          final parts = _parseMultipart(data, boundary);
          for (final part in parts) {
            _transferController.add(part);
          }
        }
        request.response.statusCode = 200;
        request.response.write(jsonEncode({'status': 'ok'}));
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  List<Map<String, dynamic>> _parseMultipart(List<int> data, String boundary) {
    final results = <Map<String, dynamic>>[];
    final text = utf8.decode(data, allowMalformed: true);
    final parts = text.split('--$boundary');
    for (final part in parts) {
      if (part.contains('Content-Disposition')) {
        final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(part);
        final filenameMatch = RegExp(r'filename="([^"]+)"').firstMatch(part);
        if (filenameMatch != null) {
          results.add({'fileName': filenameMatch.group(1), 'name': nameMatch?.group(1)});
        }
      }
    }
    return results;
  }

  String _buildHtml() => '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LocalSend Web</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:system-ui;background:#1a1a2e;color:#eee;display:flex;justify-content:center;align-items:center;min-height:100vh}#app{text-align:center;padding:40px;max-width:480px}h1{font-size:28px;margin-bottom:8px;color:#e94560}.sub{color:#aaa;margin-bottom:30px}#drop{background:#16213e;border:2px dashed #0f3460;border-radius:16px;padding:40px 20px;cursor:pointer;transition:.2s}#drop.hover{border-color:#e94560;background:#1a1a3e}#drop p{color:#888}input[type=file]{display:none}#progress{margin-top:20px}.bar{background:#0f3460;border-radius:8px;height:8px;overflow:hidden;margin-top:8px}.bar div{background:#e94560;height:100%;border-radius:8px;transition:width .3s}.file-list{margin-top:20px;text-align:left}.file-item{padding:8px 12px;background:#16213e;border-radius:8px;margin:4px 0;display:flex;justify-content:space-between;align-items:center}.success{color:#4ecca3}.pending{color:#eebc1d}</style></head>
<body><div id="app"><h1>LocalSend</h1><p class="sub">Secure Web Transfer</p>
<div id="drop" onclick="document.getElementById('fileInput').click()"><p>Drop files here or click to browse</p></div>
<input type="file" id="fileInput" multiple onchange="handleFiles(this.files)">
<div id="fileList" class="file-list"></div></div>
<script>
var TOKEN='$_token',UPLOAD_URL='/upload?token='+TOKEN;
function handleFiles(files){for(var f of files)upload(f)}
var drop=document.getElementById('drop');
drop.addEventListener('dragover',e=>{e.preventDefault();drop.className='hover'});
drop.addEventListener('dragleave',()=>drop.className='');
drop.addEventListener('drop',e=>{e.preventDefault();drop.className='';handleFiles(e.dataTransfer.files)});
function upload(file){
var item=document.createElement('div');item.className='file-item pending';
item.textContent=file.name+' (uploading...)';document.getElementById('fileList').appendChild(item);
var form=new FormData();form.append('file',file);
fetch(UPLOAD_URL,{method:'POST',body:form}).then(r=>r.json()).then(d=>{
item.className='file-item success';item.textContent=file.name+' ✓';}).catch(e=>{
item.className='file-item';item.textContent=file.name+' ✗ error';});
}
</script></body></html>''';

  Future<String?> _getLocalIp() async {
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
  }

  void dispose() {
    stop();
    _transferController.close();
  }
}
