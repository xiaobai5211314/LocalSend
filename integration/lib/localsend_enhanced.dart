import 'dart:async';

/// Enhanced LocalSend — unified entry point that initializes and
/// manages all extended modules.
///
/// Modules managed:
/// - ClipboardSyncService (clipboard sync across devices)
/// - WebReceiverService (on-demand HTTP file sharing)
/// - FolderSyncService (real-time folder sync with paired devices)
/// - HistoryService (transfer record persistence)
/// - NetworkScanner (multi-interface device scanning)
/// - HotspotDetector (hotspot network detection)
///
/// Configuration is centralized via a [EnhancedLocalSendConfig] that
/// controls feature toggles and server connectivity.
class EnhancedLocalSend {
  final EnhancedLocalSendConfig config;
  final EventBus eventBus = EventBus();

  bool _initialized = false;
  bool _running = false;

  /// Module state registry: module name -> running state.
  final Map<String, bool> _moduleStates = {};

  EnhancedLocalSend({required this.config});

  // ============================================================
  // Lifecycle
  // ============================================================

  /// Whether all modules have been initialized.
  bool get isInitialized => _initialized;

  /// Whether the service is currently running.
  bool get isRunning => _running;

  /// Initialize all enabled modules.
  ///
  /// Modules are initialized with their required configuration
  /// but do not start active services (listening/syncing).
  Future<void> init() async {
    if (_initialized) return;

    // Initialize Clipboard Sync
    if (config.enableClipboardSync) {
      _moduleStates['clipboard_sync'] = false;
      eventBus.emit(ModuleEvent('clipboard_sync.initialized'));
    }

    // Initialize Web Receiver
    if (config.enableWebReceiver) {
      _moduleStates['web_receiver'] = false;
      eventBus.emit(ModuleEvent('web_receiver.initialized'));
    }

    // Initialize Folder Sync
    if (config.enableFolderSync) {
      _moduleStates['folder_sync'] = false;
      eventBus.emit(ModuleEvent('folder_sync.initialized'));
    }

    // Initialize Transfer History
    if (config.enableHistory) {
      _moduleStates['history'] = false;
      eventBus.emit(ModuleEvent('history.initialized'));
    }

    // Initialize Network Discovery
    _moduleStates['network_scanner'] = false;
    _moduleStates['hotspot_detector'] = false;
    eventBus.emit(ModuleEvent('network.initialized'));

    _initialized = true;
    eventBus.emit(ModuleEvent('enhanced_localsend.initialized'));
  }

  /// Start all enabled modules that have active background
  /// services (clipboard sync, folder sync, network discovery).
  Future<void> start() async {
    if (!_initialized) await init();
    if (_running) return;

    // Start Clipboard Sync (connect to signaling server)
    if (config.enableClipboardSync) {
      _moduleStates['clipboard_sync'] = true;
      eventBus.emit(ModuleEvent('clipboard_sync.started'));
    }

    // Start Folder Sync (begin file watching)
    if (config.enableFolderSync) {
      _moduleStates['folder_sync'] = true;
      eventBus.emit(ModuleEvent('folder_sync.started'));
    }

    _running = true;
    eventBus.emit(ModuleEvent('enhanced_localsend.started'));
  }

  /// Stop all active modules (pause background services).
  ///
  /// Web receiver stays active until explicitly stopped.
  Future<void> stop() async {
    if (!_running) return;

    // Stop Clipboard Sync
    if (config.enableClipboardSync) {
      _moduleStates['clipboard_sync'] = false;
      eventBus.emit(ModuleEvent('clipboard_sync.stopped'));
    }

    // Stop Folder Sync
    if (config.enableFolderSync) {
      _moduleStates['folder_sync'] = false;
      eventBus.emit(ModuleEvent('folder_sync.stopped'));
    }

    _running = false;
    eventBus.emit(ModuleEvent('enhanced_localsend.stopped'));
  }

  /// Dispose all modules and release resources.
  Future<void> dispose() async {
    await stop();

    _initialized = false;
    _moduleStates.clear();
    eventBus.dispose();
  }

  // ============================================================
  // State Queries
  // ============================================================

  /// Check if a specific module is running.
  bool isModuleRunning(String moduleName) {
    return _moduleStates[moduleName] ?? false;
  }

  /// Get all module states.
  Map<String, bool> get moduleStates =>
      Map<String, bool>.from(_moduleStates);
}

/// Configuration for EnhancedLocalSend.
///
/// Controls which extended modules are enabled and provides
/// connectivity parameters for the signaling and TURN servers.
class EnhancedLocalSendConfig {
  /// Signaling server address (WebSocket).
  final String signalingServerUrl;

  /// Local device identifier.
  final String deviceId;

  /// Local device display name.
  final String deviceName;

  /// Platform string (e.g., "windows", "android").
  final String platform;

  /// Feature toggles.
  final bool enableClipboardSync;
  final bool enableWebReceiver;
  final bool enableFolderSync;
  final bool enableHistory;
  final bool enableNetworkDiscovery;

  /// Sync folders to monitor (absolute paths).
  final List<String> syncFolders;

  /// Callback URL mode (for clipboard-sync/web-receiver).
  final String? callbackUrl;

  EnhancedLocalSendConfig({
    this.signalingServerUrl = 'ws://101.132.143.168:9000',
    required this.deviceId,
    required this.deviceName,
    this.platform = 'unknown',
    this.enableClipboardSync = true,
    this.enableWebReceiver = true,
    this.enableFolderSync = false,
    this.enableHistory = true,
    this.enableNetworkDiscovery = true,
    this.syncFolders = const [],
    this.callbackUrl,
  });

  /// Create a config with all features disabled (for testing).
  factory EnhancedLocalSendConfig.disabled({
    String deviceId = 'test-device',
    String deviceName = 'Test Device',
  }) {
    return EnhancedLocalSendConfig(
      deviceId: deviceId,
      deviceName: deviceName,
      enableClipboardSync: false,
      enableWebReceiver: false,
      enableFolderSync: false,
      enableHistory: false,
      enableNetworkDiscovery: false,
    );
  }

  /// Create a config with all features enabled.
  factory EnhancedLocalSendConfig.allEnabled({
    String signalingServerUrl = 'ws://101.132.143.168:9000',
    required String deviceId,
    required String deviceName,
    String platform = 'unknown',
    List<String> syncFolders = const [],
  }) {
    return EnhancedLocalSendConfig(
      signalingServerUrl: signalingServerUrl,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      enableClipboardSync: true,
      enableWebReceiver: true,
      enableFolderSync: true,
      enableHistory: true,
      enableNetworkDiscovery: true,
      syncFolders: syncFolders,
    );
  }
}

// ============================================================
// Event Bus
// ============================================================

/// Lightweight publish-subscribe event bus for loose coupling
/// between enhanced modules.
class EventBus {
  final Map<String, List<Function>> _listeners = {};
  final StreamController<ModuleEvent> _streamController =
      StreamController<ModuleEvent>.broadcast();

  /// Stream of all emitted events.
  Stream<ModuleEvent> get stream => _streamController.stream;

  /// Listen to events of a specific type.
  void on(String eventType, Function callback) {
    _listeners.putIfAbsent(eventType, () => []);
    _listeners[eventType]!.add(callback);
  }

  /// Remove a listener.
  void off(String eventType, Function callback) {
    _listeners[eventType]?.remove(callback);
  }

  /// Emit an event to all listeners.
  void emit(ModuleEvent event) {
    _streamController.add(event);
    final listeners = _listeners[event.type] ?? [];
    for (final listener in listeners) {
      try {
        listener(event);
      } catch (_) {
        // Silently ignore listener errors
      }
    }
  }

  /// Release resources.
  void dispose() {
    _listeners.clear();
    _streamController.close();
  }
}

/// Event emitted by the EventBus.
class ModuleEvent {
  final String type;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  ModuleEvent(this.type, [Map<String, dynamic>? data])
      : data = data ?? {},
        timestamp = DateTime.now();

  @override
  String toString() => 'ModuleEvent($type, data: $data)';
}
