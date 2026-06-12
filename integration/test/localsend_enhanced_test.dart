import 'package:test/test.dart';

import '../lib/localsend_enhanced.dart';

void main() {
  group('EnhancedLocalSend', () {
    test('should initialize with disabled config', () async {
      final config = EnhancedLocalSendConfig.disabled(
        deviceId: 'test-001',
        deviceName: 'Test Device',
      );
      final enhanced = EnhancedLocalSend(config: config);

      expect(enhanced.isInitialized, isFalse);
      expect(enhanced.isRunning, isFalse);

      await enhanced.init();

      expect(enhanced.isInitialized, isTrue);
      expect(enhanced.isRunning, isFalse);

      // All modules should be in initialized but stopped state
      expect(enhanced.isModuleRunning('clipboard_sync'), isFalse);
      expect(enhanced.isModuleRunning('web_receiver'), isFalse);
      expect(enhanced.isModuleRunning('folder_sync'), isFalse);
      expect(enhanced.isModuleRunning('history'), isFalse);

      await enhanced.dispose();
      expect(enhanced.isInitialized, isFalse);
    });

    test('should initialize with all enabled config', () async {
      final config = EnhancedLocalSendConfig.allEnabled(
        deviceId: 'test-002',
        deviceName: 'All Enabled',
      );
      final enhanced = EnhancedLocalSend(config: config);

      await enhanced.init();
      expect(enhanced.isInitialized, isTrue);

      final states = enhanced.moduleStates;
      expect(states.containsKey('clipboard_sync'), isTrue);
      expect(states.containsKey('web_receiver'), isTrue);
      expect(states.containsKey('folder_sync'), isTrue);
      expect(states.containsKey('history'), isTrue);
      expect(states.containsKey('network_scanner'), isTrue);
      expect(states.containsKey('hotspot_detector'), isTrue);

      await enhanced.dispose();
    });

    test('start/stop lifecycle', () async {
      final config = EnhancedLocalSendConfig(
        deviceId: 'test-003',
        deviceName: 'Lifecycle Test',
        enableClipboardSync: true,
        enableFolderSync: true,
        enableWebReceiver: false,
        enableHistory: false,
        enableNetworkDiscovery: false,
      );
      final enhanced = EnhancedLocalSend(config: config);

      await enhanced.init();
      expect(enhanced.isRunning, isFalse);

      await enhanced.start();
      expect(enhanced.isRunning, isTrue);
      expect(enhanced.isModuleRunning('clipboard_sync'), isTrue);
      expect(enhanced.isModuleRunning('folder_sync'), isTrue);

      await enhanced.stop();
      expect(enhanced.isRunning, isFalse);
      expect(enhanced.isModuleRunning('clipboard_sync'), isFalse);
      expect(enhanced.isModuleRunning('folder_sync'), isFalse);

      await enhanced.dispose();
    });

    test('double init should be idempotent', () async {
      final config = EnhancedLocalSendConfig.disabled(
        deviceId: 'test-004',
        deviceName: 'Idempotent Test',
      );
      final enhanced = EnhancedLocalSend(config: config);

      await enhanced.init();
      await enhanced.init(); // Second init should be safe
      expect(enhanced.isInitialized, isTrue);

      await enhanced.dispose();
    });

    test('event bus receives initialization events', () async {
      final config = EnhancedLocalSendConfig.allEnabled(
        deviceId: 'test-005',
        deviceName: 'Event Test',
      );
      final enhanced = EnhancedLocalSend(config: config);

      final events = <String>[];
      enhanced.eventBus.on('clipboard_sync.initialized', (_) {
        events.add('clipboard_init');
      });
      enhanced.eventBus.on('enhanced_localsend.initialized', (_) {
        events.add('global_init');
      });

      await enhanced.init();

      expect(events.contains('clipboard_init'), isTrue);
      expect(events.contains('global_init'), isTrue);

      await enhanced.dispose();
    });
  });

  group('EnhancedLocalSendConfig', () {
    test('disabled factory creates config with all features off', () {
      final config = EnhancedLocalSendConfig.disabled(
        deviceId: 'dev-1',
        deviceName: 'Test',
      );

      expect(config.enableClipboardSync, isFalse);
      expect(config.enableWebReceiver, isFalse);
      expect(config.enableFolderSync, isFalse);
      expect(config.enableHistory, isFalse);
      expect(config.enableNetworkDiscovery, isFalse);
      expect(config.deviceId, equals('dev-1'));
      expect(config.deviceName, equals('Test'));
      expect(config.signalingServerUrl, equals('ws://101.132.143.168:9000'));
    });

    test('allEnabled factory creates config with all features on', () {
      final config = EnhancedLocalSendConfig.allEnabled(
        deviceId: 'dev-2',
        deviceName: 'Full',
        syncFolders: ['/tmp/sync1', '/tmp/sync2'],
      );

      expect(config.enableClipboardSync, isTrue);
      expect(config.enableWebReceiver, isTrue);
      expect(config.enableFolderSync, isTrue);
      expect(config.enableHistory, isTrue);
      expect(config.enableNetworkDiscovery, isTrue);
      expect(config.syncFolders, equals(['/tmp/sync1', '/tmp/sync2']));
    });

    test('custom server URL is preserved', () {
      final config = EnhancedLocalSendConfig(
        deviceId: 'dev-3',
        deviceName: 'Custom',
        signalingServerUrl: 'ws://10.0.0.1:9000',
      );

      expect(config.signalingServerUrl, equals('ws://10.0.0.1:9000'));
    });
  });

  group('EventBus', () {
    test('emit and listen', () async {
      final bus = EventBus();
      final received = <ModuleEvent>[];

      bus.on('test.event', (event) => received.add(event as ModuleEvent));

      final event = ModuleEvent('test.event', {'key': 'value'});
      bus.emit(event);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(received.length, equals(1));
      expect(received[0].type, equals('test.event'));
      expect(received[0].data['key'], equals('value'));

      bus.dispose();
    });

    test('multiple listeners for same event', () async {
      final bus = EventBus();
      int count = 0;

      bus.on('counter', (_) => count++);
      bus.on('counter', (_) => count++);
      bus.on('counter', (_) => count++);

      bus.emit(ModuleEvent('counter'));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(count, equals(3));
      bus.dispose();
    });

    test('off removes listener', () async {
      final bus = EventBus();
      int count = 0;

      void callback(ModuleEvent e) => count++;

      bus.on('test', callback);
      bus.emit(ModuleEvent('test'));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(count, equals(1));

      bus.off('test', callback);
      bus.emit(ModuleEvent('test'));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(count, equals(1)); // Should not increment

      bus.dispose();
    });

    test('listener errors do not block other listeners', () async {
      final bus = EventBus();
      int goodCount = 0;

      bus.on('test', (_) => throw Exception('Bad listener'));
      bus.on('test', (_) => goodCount++);

      bus.emit(ModuleEvent('test'));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(goodCount, equals(1));

      bus.dispose();
    });

    test('stream receives events', () async {
      final bus = EventBus();
      final events = <ModuleEvent>[];

      final sub = bus.stream.listen((event) => events.add(event));

      bus.emit(ModuleEvent('a'));
      bus.emit(ModuleEvent('b'));
      bus.emit(ModuleEvent('c'));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(3));
      expect(events.map((e) => e.type), equals(['a', 'b', 'c']));

      await sub.cancel();
      bus.dispose();
    });
  });
}
