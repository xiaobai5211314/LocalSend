import 'dart:io';
import 'dart:async';
import 'package:watcher/watcher.dart';
import 'package:dio/dio.dart';
import 'signaling_client.dart';

class FolderSyncService {
  final SignalingClient signaling;
  final String folderPath;
  final Dio _dio = Dio();
  StreamSubscription? _fileWatcher;
  bool _syncing = false;

  final _syncEventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get syncEvents => _syncEventController.stream;

  FolderSyncService(this.signaling, this.folderPath);

  void start() {
    _fileWatcher = DirectoryWatcher(folderPath).events.listen((event) {
      if (_syncing) return;
      _syncing = true;
      _handleFileEvent(event).whenComplete(() => _syncing = false);
    });
  }

  Future<void> _handleFileEvent(WatchEvent event) async {
    final path = event.path;
    final file = File(path);
    if (!await file.exists()) return;
    final name = path.split(Platform.pathSeparator).last;

    _syncEventController.add({'type': 'local_change', 'file': name, 'path': path});

    for (final device in signaling.devices) {
      signaling.sendTo(device['device_id']!, 'folder_sync_notify', {
        'action': 'changed',
        'file': name,
        'size': await file.length(),
      });
    }
  }

  Future<void> handleRemoteSync(Map<String, dynamic> payload) async {
    final action = payload['action'] as String?;
    final fileName = payload['file'] as String?;
    if (fileName == null) return;

    final targetPath = '$folderPath${Platform.pathSeparator}$fileName';
    if (action == 'delete') {
      final f = File(targetPath);
      if (await f.exists()) await f.delete();
      _syncEventController.add({'type': 'remote_delete', 'file': fileName});
    }
  }

  void stop() {
    _fileWatcher?.cancel();
  }

  void dispose() {
    stop();
    _dio.close();
    _syncEventController.close();
  }
}
