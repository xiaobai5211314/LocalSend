import 'dart:async';
import 'package:flutter/services.dart';
import 'package:clipboard/clipboard.dart';
import 'signaling_client.dart';

class ClipboardSyncService {
  final SignalingClient signaling;
  Timer? _pollTimer;
  String? _lastContent;
  bool _enabled = false;

  final _localCopyController = StreamController<String>.broadcast();
  final _remoteCopyController = StreamController<String>.broadcast();

  Stream<String> get onLocalCopy => _localCopyController.stream;
  Stream<String> get onRemoteCopy => _remoteCopyController.stream;
  bool get enabled => _enabled;

  ClipboardSyncService(this.signaling);

  void start() {
    if (_enabled) return;
    _enabled = true;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 800), (_) => _checkClipboard());
    signaling.messageStream.listen((msg) {
      if (msg['type'] == 'clipboard_update') {
        final content = msg['payload']['text'] as String?;
        if (content != null) {
          _lastContent = content;
          Clipboard.setData(ClipboardData(text: content));
          _remoteCopyController.add(content);
        }
      }
    });
  }

  void _checkClipboard() async {
    try {
      final text = await FlutterClipboard.paste();
      if (text.isNotEmpty && text != _lastContent) {
        _lastContent = text;
        _localCopyController.add(text);
        for (final device in signaling.devices) {
          signaling.sendTo(device['device_id']!, 'clipboard_update', {'text': text});
        }
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    _enabled = false;
    _pollTimer?.cancel();
  }

  void dispose() {
    stop();
    _localCopyController.close();
    _remoteCopyController.close();
  }
}
