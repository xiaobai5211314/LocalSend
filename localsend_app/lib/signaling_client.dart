import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingClient {
  static const String defaultServer = 'ws://101.132.143.168:9000';
  final String serverUrl;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  String? deviceId;
  String deviceName;
  bool _connected = false;
  bool get connected => _connected;

  final _deviceListController = StreamController<List<Map<String, String>>>.broadcast();
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  Stream<List<Map<String, String>>> get deviceListStream => _deviceListController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  Timer? _heartbeatTimer;
  List<Map<String, String>> _devices = [];

  SignalingClient({this.serverUrl = defaultServer, this.deviceName = 'Unknown'});

  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      await _channel!.ready;
      _connected = true;
      _connectionController.add(true);

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (err) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
      );

      _register();
      _startHeartbeat();
    } catch (e) {
      _connected = false;
      _connectionController.add(false);
      Future.delayed(const Duration(seconds: 3), () => connect());
    }
  }

  void _register() {
    _send({'type': 'register', 'payload': {'device_name': deviceName}});
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _send({'type': 'ping'});
    });
  }

  void _send(Map<String, dynamic> msg) {
    if (_channel != null && _connected) {
      _channel!.sink.add(jsonEncode(msg));
    }
  }

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      switch (type) {
        case 'registered':
          deviceId = msg['payload']['device_id'];
          requestDeviceList();
          break;
        case 'device_list':
          _devices = (msg['payload']['devices'] as List)
              .map((d) => Map<String, String>.from(d))
              .toList();
          _deviceListController.add(List.from(_devices));
          break;
        case 'pong':
          break;
        case 'offer':
        case 'answer':
        case 'ice_candidate':
        case 'clipboard_update':
        case 'file_transfer':
          _messageController.add(Map<String, dynamic>.from(msg));
          break;
      }
    } catch (_) {}
  }

  void _handleDisconnect() {
    _connected = false;
    _heartbeatTimer?.cancel();
    _subscription?.cancel();
    _connectionController.add(false);
    Future.delayed(const Duration(seconds: 3), () => connect());
  }

  void requestDeviceList() {
    _send({'type': 'request_device_list'});
  }

  void sendTo(String targetId, String type, Map<String, dynamic> payload) {
    _send({'type': type, 'to': targetId, 'payload': payload});
  }

  List<Map<String, String>> get devices => List.from(_devices);

  void disconnect() {
    _heartbeatTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;
    _connectionController.add(false);
  }

  void dispose() {
    disconnect();
    _deviceListController.close();
    _messageController.close();
    _connectionController.close();
  }
}
