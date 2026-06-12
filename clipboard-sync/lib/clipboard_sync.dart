import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'url_relay.dart';

/// JSON message types used with the signaling server.
class SignalingMessageType {
  static const String register = 'register';
  static const String registerAck = 'register_ack';
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String listDevices = 'list_devices';
  static const String deviceList = 'device_list';
  static const String deviceJoined = 'device_joined';
  static const String deviceLeft = 'device_left';
  static const String clipboard = 'clipboard';
  static const String error = 'error';
}

/// Represents a remote device known to the signaling server.
class SyncDevice {
  final String deviceId;
  final String deviceName;
  final String? platform;
  final String? model;
  final bool online;
  final int? lastSeen;

  SyncDevice({
    required this.deviceId,
    required this.deviceName,
    this.platform,
    this.model,
    this.online = true,
    this.lastSeen,
  });

  factory SyncDevice.fromJson(Map<String, dynamic> json) {
    return SyncDevice(
      deviceId: json['device_id'] as String,
      deviceName: json['device_name'] as String,
      platform: json['platform'] as String?,
      model: json['model'] as String?,
      online: json['online'] as bool? ?? true,
      lastSeen: json['last_seen'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_name': deviceName,
        if (platform != null) 'platform': platform,
        if (model != null) 'model': model,
        'online': online,
        if (lastSeen != null) 'last_seen': lastSeen,
      };
}

/// Connection state of the clipboard sync service.
enum SyncConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Callback type for connection state changes.
typedef ConnectionStateCallback = void Function(
    SyncConnectionState oldState, SyncConnectionState newState);

/// Callback type for received clipboard content.
typedef ClipboardReceiveCallback = void Function(
    String mimeType, String content, String? fromDeviceId);

/// Callback type for device list updates.
typedef DeviceListCallback = void Function(List<SyncDevice> devices);

/// Clipboard sync service for LocalSend.
///
/// Manages WebSocket connection to the signaling server for clipboard
/// synchronization between devices. Features:
/// - Automatic reconnection with exponential backoff
/// - Device registration and discovery
/// - Clipboard content deduplication via SHA-256 hashing
/// - URL auto-detection and relay
/// - Cross-platform clipboard reading/writing via MethodChannel
class ClipboardSyncService {
  static const _channel = MethodChannel('localsend/clipboard_sync');

  // --- Configuration ---

  /// Signaling server URL (ws:// or wss://).
  final String serverUrl;

  /// Local device identifier.
  final String deviceId;

  /// Local device display name.
  final String deviceName;

  /// Platform identifier (e.g., "windows", "android").
  final String platform;

  /// Reconnection backoff durations in seconds.
  static const List<int> _backoffDurations = [1, 2, 4, 8, 16, 30];

  // --- State ---

  WebSocketChannel? _channel;
  SyncConnectionState _connectionState = SyncConnectionState.disconnected;
  int _reconnectAttempt = 0;
  Timer? _heartbeatTimer;
  Timer? _clipboardPollTimer;
  String? _lastSentHash;
  String? _sessionToken;
  bool _disposed = false;

  // --- Callbacks ---

  ConnectionStateCallback? onConnectionStateChanged;
  ClipboardReceiveCallback? onClipboardReceived;
  DeviceListCallback? onDeviceListUpdated;

  // --- Device registry ---

  final Map<String, SyncDevice> _devices = {};

  /// Create a new ClipboardSyncService instance.
  ClipboardSyncService({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    this.platform = 'unknown',
    this.onConnectionStateChanged,
    this.onClipboardReceived,
    this.onDeviceListUpdated,
  });

  // ============================================================
  // Connection Management
  // ============================================================

  /// Current connection state.
  SyncConnectionState get connectionState => _connectionState;

  /// Whether currently connected to the signaling server.
  bool get isConnected => _connectionState == SyncConnectionState.connected;

  /// List of known remote devices.
  List<SyncDevice> get devices => _devices.values.toList();

  /// Connect to the signaling server.
  ///
  /// Establishes a WebSocket connection and performs device registration.
  /// If the connection drops, automatic reconnection with exponential
  /// backoff is triggered.
  Future<void> connect() async {
    if (_disposed) return;
    _setState(SyncConnectionState.connecting);
    await _doConnect();
  }

  Future<void> _doConnect() async {
    try {
      final uri = Uri.parse(serverUrl);
      _channel = WebSocketChannel.connect(uri);

      // Wait for the WebSocket to be ready, then register
      await _channel!.ready;
      await _sendRegister();

      _reconnectAttempt = 0;
      _setState(SyncConnectionState.connected);
      _startHeartbeat();
      _startClipboardPolling();

      // Listen for incoming messages
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
    } catch (e) {
      _scheduleReconnect();
    }
  }

  /// Disconnect from the signaling server.
  Future<void> disconnect() async {
    _disposed = true;
    _stopHeartbeat();
    _stopClipboardPolling();
    await _channel?.sink.close();
    _channel = null;
    _setState(SyncConnectionState.disconnected);
  }

  /// Force a reconnection attempt, resetting backoff.
  Future<void> reconnect() async {
    _reconnectAttempt = 0;
    await _channel?.sink.close();
    _channel = null;
    _setState(SyncConnectionState.reconnecting);
    await _doConnect();
  }

  void _onError(dynamic error) {
    _scheduleReconnect();
  }

  void _onDone() {
    if (!_disposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _stopHeartbeat();
    _stopClipboardPolling();
    _channel = null;
    _setState(SyncConnectionState.reconnecting);

    final delay = _backoffDurations[_reconnectAttempt.clamp(
        0, _backoffDurations.length - 1)];
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 100);

    Future.delayed(Duration(seconds: delay), () {
      if (!_disposed && _connectionState == SyncConnectionState.reconnecting) {
        _doConnect();
      }
    });
  }

  // ============================================================
  // Registration
  // ============================================================

  Future<void> _sendRegister() async {
    final msg = {
      'type': SignalingMessageType.register,
      'from': deviceId,
      'payload': {
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
        'protocol_version': 1,
      },
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  // ============================================================
  // Heartbeat
  // ============================================================

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_channel != null && isConnected) {
        final msg = {
          'type': SignalingMessageType.ping,
          'from': deviceId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
        _channel?.sink.add(jsonEncode(msg));
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ============================================================
  // Clipboard Polling
  // ============================================================

  void _startClipboardPolling() {
    _stopClipboardPolling();
    _clipboardPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _checkAndSendClipboard();
    });
  }

  void _stopClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = null;
  }

  /// Read local clipboard, compute hash, and send if changed.
  Future<void> _checkAndSendClipboard() async {
    try {
      final content = await readClipboard();
      if (content == null || content.isEmpty) return;

      final hash = _computeHash(content);
      if (hash == _lastSentHash) return; // Deduplicate

      _lastSentHash = hash;
      await sendClipboard(content);
    } catch (_) {
      // Clipboard read may fail on some platforms
    }
  }

  // ============================================================
  // Clipboard Read / Write
  // ============================================================

  /// Read the current clipboard content via platform channel.
  ///
  /// Returns the text content, or null if clipboard is empty.
  Future<String?> readClipboard() async {
    try {
      final result =
          await _channel.invokeMethod<String>('readClipboard');
      return result;
    } on MissingPluginException {
      // Fallback: use Flutter's Clipboard if MethodChannel unavailable
      return null;
    }
  }

  /// Write content to the system clipboard via platform channel.
  Future<void> writeClipboard(String content) async {
    try {
      await _channel.invokeMethod('writeClipboard', {'text': content});
    } on MissingPluginException {
      // Fallback handled by platform code
    }
  }

  /// Send clipboard content to all connected devices.
  Future<void> sendClipboard(String content, {String? targetDeviceId}) async {
    if (_channel == null || !isConnected) return;

    final hash = _computeHash(content);
    final isUrl = UrlRelayHandler.detectPlatform(content) != null;

    final payload = {
      'content_hash': hash,
      'mime_type': 'text/plain',
      'text': content,
      'is_url': isUrl,
      if (isUrl) 'url': content,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final msg = {
      'type': SignalingMessageType.clipboard,
      'from': deviceId,
      if (targetDeviceId != null) 'to': targetDeviceId,
      'payload': payload,
    };

    _channel?.sink.add(jsonEncode(msg));
  }

  // ============================================================
  // Message Handling
  // ============================================================

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final msgType = msg['type'] as String?;
      if (msgType == null) return;

      switch (msgType) {
        case SignalingMessageType.registerAck:
          _handleRegisterAck(msg);
          break;
        case SignalingMessageType.pong:
          // Heartbeat response, nothing to do
          break;
        case SignalingMessageType.deviceList:
          _handleDeviceList(msg);
          break;
        case SignalingMessageType.deviceJoined:
          _handleDeviceJoined(msg);
          break;
        case SignalingMessageType.deviceLeft:
          _handleDeviceLeft(msg);
          break;
        case SignalingMessageType.clipboard:
          _handleClipboardReceived(msg);
          break;
        case SignalingMessageType.error:
          _handleError(msg);
          break;
      }
    } catch (_) {
      // Malformed message, ignore
    }
  }

  void _handleRegisterAck(Map<String, dynamic> msg) {
    _sessionToken = msg['payload']?['session_token'] as String?;
  }

  void _handleDeviceList(Map<String, dynamic> msg) {
    final list = msg['payload']?['devices'] as List<dynamic>?;
    if (list == null) return;

    _devices.clear();
    for (final item in list) {
      final device = SyncDevice.fromJson(item as Map<String, dynamic>);
      if (device.deviceId != deviceId) {
        _devices[device.deviceId] = device;
      }
    }
    onDeviceListUpdated?.call(devices);
  }

  void _handleDeviceJoined(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>?;
    if (payload == null) return;

    final device = SyncDevice.fromJson(payload);
    if (device.deviceId != deviceId) {
      _devices[device.deviceId] = device;
      onDeviceListUpdated?.call(devices);
    }
  }

  void _handleDeviceLeft(Map<String, dynamic> msg) {
    final fromId = msg['from'] as String?;
    if (fromId != null) {
      _devices.remove(fromId);
      onDeviceListUpdated?.call(devices);
    }
  }

  void _handleClipboardReceived(Map<String, dynamic> msg) {
    final fromId = msg['from'] as String?;
    if (fromId == deviceId) return; // Ignore own messages

    final payload = msg['payload'] as Map<String, dynamic>?;
    if (payload == null) return;

    final mimeType = payload['mime_type'] as String? ?? 'text/plain';
    final text = payload['text'] as String?;
    if (text == null || text.isEmpty) return;

    // Write to local clipboard
    writeClipboard(text);

    // Auto-open URL if applicable
    if (payload['is_url'] == true) {
      final url = payload['url'] as String?;
      if (url != null) {
        UrlRelayHandler.openUrl(url);
      }
    }

    // Notify callback
    onClipboardReceived?.call(mimeType, text, fromId);
  }

  void _handleError(Map<String, dynamic> msg) {
    final error = msg['error'] as Map<String, dynamic>?;
    final code = error?['code'] as int?;
    final message = error?['message'] as String?;

    if (code == 1002) {
      // NOT_REGISTERED: re-register
      _sendRegister();
    }
  }

  // ============================================================
  // Device Discovery
  // ============================================================

  /// Request the current device list from the server.
  void requestDeviceList() {
    if (_channel == null || !isConnected) return;
    final msg = {
      'type': SignalingMessageType.listDevices,
      'from': deviceId,
    };
    _channel?.sink.add(jsonEncode(msg));
  }

  // ============================================================
  // Foreground Service
  // ============================================================

  /// Request foreground service permission (Android).
  ///
  /// On Android 14+, a persistent notification is required for
  /// background clipboard monitoring. This method shows a prompt
  /// to the user to grant the necessary permissions.
  static Future<bool> requestForegroundService() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('requestForegroundService');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Show a foreground service notification (Android).
  ///
  /// Displays "LocalSend clipboard sync is active" notification.
  static Future<void> showForegroundNotification() async {
    try {
      await _channel.invokeMethod('showForegroundNotification');
    } on MissingPluginException {
      // Not available on this platform
    }
  }

  // ============================================================
  // Helpers
  // ============================================================

  void _setState(SyncConnectionState newState) {
    if (_connectionState == newState) return;
    final oldState = _connectionState;
    _connectionState = newState;
    onConnectionStateChanged?.call(oldState, newState);
  }

  /// Compute SHA-256 hash for clipboard deduplication.
  String _computeHash(String content) {
    final bytes = utf8.encode(content);
    final digest = crypto.sha256.convert(bytes);
    return digest.toString();
  }
}
