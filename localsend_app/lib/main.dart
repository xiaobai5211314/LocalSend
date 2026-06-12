import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'signaling_client.dart';
import 'clipboard_sync.dart';
import 'transfer_history.dart';
import 'folder_sync.dart';
import 'web_receiver.dart';
import 'network_discovery.dart';
import 'file_transfer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(LocalSendEnhancedApp(prefs: prefs));
}

class LocalSendEnhancedApp extends StatelessWidget {
  final SharedPreferences prefs;
  const LocalSendEnhancedApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalSend 增强版',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE94560),
          brightness: Brightness.dark,
        ),
      ),
      home: MainScreen(prefs: prefs),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const MainScreen({super.key, required this.prefs});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  final SignalingClient _signaling = SignalingClient(deviceName: Platform.localHostname);
  ClipboardSyncService? _clipboardSync;
  TransferHistoryService? _historyService;
  FolderSyncService? _folderSync;
  WebReceiverService? _webReceiver;
  NetworkDiscoveryService? _networkDiscovery;
  FileTransferService? _fileTransfer;

  bool _connected = false;
  List<Map<String, String>> _devices = [];
  List<TransferRecord> _records = [];
  String? _syncFolder;
  String? _qrUrl;
  bool _clipboardEnabled = false;
  bool _webServerRunning = false;
  bool _folderSyncEnabled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    final savedName = widget.prefs.getString('device_name');
    if (savedName != null && savedName.isNotEmpty) {
      _signaling.deviceName = savedName;
    }
    final savedFolder = widget.prefs.getString('sync_folder');
    if (savedFolder != null) _syncFolder = savedFolder;
    _clipboardEnabled = widget.prefs.getBool('clipboard_enabled') ?? false;
    _folderSyncEnabled = widget.prefs.getBool('folder_sync_enabled') ?? false;

    _historyService = TransferHistoryService();
    _networkDiscovery = NetworkDiscoveryService();
    _fileTransfer = FileTransferService();
    _initServices();
  }

  Future<void> _initServices() async {
    _signaling.connectionStream.listen((connected) {
      if (mounted) setState(() => _connected = connected);
    });
    _signaling.deviceListStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _signaling.messageStream.listen((msg) {
      final type = msg['type'] as String?;
      print('[MSG] received type=$type');
      if (type == 'file_transfer') {
        print('[MSG] file_transfer payload=${msg["payload"]}');
        _handleIncomingFile(msg);
      }
    });

    _historyService!.recordsStream.listen((records) {
      if (mounted) setState(() => _records = records);
    });

    await _signaling.connect();

    if (_clipboardEnabled) {
      _clipboardSync = ClipboardSyncService(_signaling);
      _clipboardSync!.start();
      _clipboardSync!.onLocalCopy.listen((_) {});
    }
    if (_folderSyncEnabled && _syncFolder != null) {
      _folderSync = FolderSyncService(_signaling, _syncFolder!);
      _folderSync!.start();
    }
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyService != null) {
      final records = await _historyService!.getRecords();
      if (mounted) setState(() => _records = records);
    }
  }

  Future<void> _pickSyncFolder() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() => _syncFolder = result);
      await widget.prefs.setString('sync_folder', result);
      _folderSync?.dispose();
      _folderSync = FolderSyncService(_signaling, result);
      if (_folderSyncEnabled) _folderSync!.start();
    }
  }

  Future<void> _toggleClipboard(bool val) async {
    setState(() => _clipboardEnabled = val);
    await widget.prefs.setBool('clipboard_enabled', val);
    if (val) {
      _clipboardSync ??= ClipboardSyncService(_signaling);
      _clipboardSync!.start();
      _clipboardSync!.onLocalCopy.listen((_) {});
    } else {
      _clipboardSync?.stop();
    }
  }

  Future<void> _toggleWebServer(bool val) async {
    if (val) {
      _webReceiver ??= WebReceiverService();
      await _webReceiver!.start();
      setState(() {
        _webServerRunning = true;
        _qrUrl = _webReceiver!.url;
      });
    } else {
      _webReceiver?.stop();
      setState(() => _webServerRunning = false);
    }
  }

  Future<void> _toggleFolderSync(bool val) async {
    setState(() => _folderSyncEnabled = val);
    await widget.prefs.setBool('folder_sync_enabled', val);
    if (val && _syncFolder != null) {
      _folderSync ??= FolderSyncService(_signaling, _syncFolder!);
      _folderSync!.start();
    } else {
      _folderSync?.stop();
    }
  }

  Future<void> _sendFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    for (final file in result.files) {
      if (file.path == null) continue;
      final record = TransferRecord(
        fileName: file.name,
        fileSize: file.size,
        direction: 'sent',
        remoteDevice: _devices.isNotEmpty ? _devices.first['device_name'] ?? 'unknown' : 'unknown',
        status: 'pending',
      );
      final id = await _historyService!.addRecord(record);

      try {
        final downloadUrl = await _fileTransfer!.serveFile(file.path!);
        print('[SEND] file=${file.name} url=$downloadUrl devices=${_devices.length}');

        for (final device in _devices) {
          if (device['device_id'] == _signaling.deviceId) continue;
          print('[SEND] sending to ${device["device_name"]} (${device["device_id"]})');
          _signaling.sendTo(device['device_id']!, 'file_transfer', {
            'fileName': file.name,
            'size': file.size,
            'downloadUrl': downloadUrl,
            'senderName': _signaling.deviceName,
          });
        }

        await _historyService!.updateProgress(id, 100, 'completed');
      } catch (e) {
        await _historyService!.updateProgress(id, 0, 'failed');
      }
      _loadHistory();
    }
  }

  Future<void> _handleIncomingFile(Map<String, dynamic> msg) async {
    final payload = msg['payload'] as Map<String, dynamic>;
    final fileName = payload['fileName'] as String;
    final size = payload['size'] as int;
    final downloadUrl = payload['downloadUrl'] as String;
    final senderName = payload['senderName'] as String? ?? 'unknown';
    print('[RECV] file=$fileName size=$size url=$downloadUrl from=$senderName');

    final record = TransferRecord(
      fileName: fileName,
      fileSize: size,
      direction: 'received',
      remoteDevice: senderName,
      status: 'transferring',
    );
    final id = await _historyService!.addRecord(record);
    _loadHistory();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}${Platform.pathSeparator}received');
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final savePath = '${saveDir.path}${Platform.pathSeparator}$fileName';
      await FileTransferService.downloadFile(downloadUrl, savePath);
      await _historyService!.updateProgress(id, 100, 'completed');
    } catch (e) {
      await _historyService!.updateProgress(id, 0, 'failed');
    }
    _loadHistory();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _signaling.dispose();
    _clipboardSync?.dispose();
    _folderSync?.dispose();
    _webReceiver?.dispose();
    _networkDiscovery?.dispose();
    _historyService?.dispose();
    _fileTransfer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('LocalSend 增强版'),
            const Spacer(),
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _connected ? Colors.lightGreenAccent : Colors.redAccent,
              ),
            ),
          ],
        ),
        bottom: TabBar(controller: _tabController, tabs: const [
          Tab(text: '设备'), Tab(text: '传输'), Tab(text: '网页'), Tab(text: '设置'),
        ]),
      ),
      body: TabBarView(controller: _tabController, children: [
        _buildDevicesTab(),
        _buildTransferTab(),
        _buildWebTab(),
        _buildSettingsTab(),
      ]),
    );
  }

  Widget _buildDevicesTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('我的设备: ${_signaling.deviceName}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('ID: ${_signaling.deviceId ?? "连接中..."}', style: TextStyle(color: Colors.grey[400])),
            const SizedBox(height: 4),
            Text('服务器: ws://101.132.143.168:9000', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              _connected
                ? const Chip(label: Text('已连接'), backgroundColor: Colors.green)
                : const Chip(label: Text('未连接'), backgroundColor: Colors.red),
              const SizedBox(width: 8),
              if (_clipboardEnabled)
                const Chip(label: Text('剪贴板同步'), backgroundColor: Colors.blue),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Text('在线设备', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const Spacer(),
        TextButton.icon(onPressed: _sendFiles, icon: const Icon(Icons.send), label: const Text('发送文件')),
      ]),
      const SizedBox(height: 8),
      if (_devices.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无在线设备')))),
      ...(_devices.map((d) => Card(
        child: ListTile(
          leading: const Icon(Icons.devices, color: Colors.lightGreenAccent),
          title: Text(d['device_name'] ?? 'Unknown'),
          subtitle: Text(d['device_id'] ?? ''),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: () {},
        ),
      ))),
    ]);
  }

  Widget _buildTransferTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('传输历史', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (_records.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无传输记录')))),
      ...(_records.map((r) => Card(
        child: ListTile(
          leading: Icon(r.direction == 'sent' ? Icons.upload : Icons.download,
            color: r.status == 'failed' ? Colors.redAccent : null),
          title: Text(r.fileName),
          subtitle: Text('${r.remoteDevice} · ${_formatSize(r.fileSize)} · ${_trStatus(r.status)}'),
          trailing: r.status == 'completed'
            ? const Icon(Icons.check_circle, color: Colors.green)
            : r.status == 'failed'
              ? const Icon(Icons.error, color: Colors.redAccent)
              : Text('${r.progress}%'),
        ),
      ))),
    ]);
  }

  Widget _buildWebTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            const Text('网页接收', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('允许其他设备通过浏览器发送文件', style: TextStyle(color: Colors.grey[400])),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('启用网页服务器'),
              value: _webServerRunning,
              onChanged: _toggleWebServer,
            ),
            if (_webServerRunning && _qrUrl != null) ...[
              const SizedBox(height: 8),
              Text('URL: $_qrUrl', style: const TextStyle(fontSize: 12)),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _buildSettingsTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(
        child: Column(children: [
          ListTile(
            title: const Text('设备名称'),
            subtitle: Text(_signaling.deviceName),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final controller = TextEditingController(text: _signaling.deviceName);
              final name = await showDialog<String>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('设备名称'),
                  content: TextField(controller: controller, autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('保存')),
                  ],
                ),
              );
              if (name != null && name.isNotEmpty) {
                setState(() => _signaling.deviceName = name);
                await widget.prefs.setString('device_name', name);
                _signaling.disconnect();
                _signaling.connect();
              }
            },
          ),
          SwitchListTile(
            title: const Text('剪贴板同步'),
            subtitle: const Text('跨设备共享剪贴板'),
            value: _clipboardEnabled,
            onChanged: _toggleClipboard,
          ),
          SwitchListTile(
            title: const Text('文件夹同步'),
            subtitle: Text(_syncFolder ?? '未选择文件夹'),
            value: _folderSyncEnabled,
            onChanged: _toggleFolderSync,
          ),
          ListTile(
            title: const Text('同步文件夹'),
            subtitle: Text(_syncFolder ?? '点击选择'),
            trailing: const Icon(Icons.folder_open),
            onTap: _pickSyncFolder,
          ),
          SwitchListTile(
            title: const Text('网页接收'),
            subtitle: const Text('通过浏览器接收文件'),
            value: _webServerRunning,
            onChanged: _toggleWebServer,
          ),
        ]),
      ),
      Card(
        child: Column(children: [
          const ListTile(title: Text('服务器信息')),
          ListTile(
            title: const Text('信令服务器'),
            subtitle: const Text('ws://101.132.143.168:9000'),
          ),
          ListTile(
            title: const Text('TURN 服务器'),
            subtitle: const Text('101.132.143.168:3478'),
          ),
        ]),
      ),
    ]);
  }

  String _trStatus(String status) {
    switch (status) {
      case 'pending': return '等待中';
      case 'transferring': return '传输中';
      case 'completed': return '已完成';
      case 'failed': return '失败';
      default: return status;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
