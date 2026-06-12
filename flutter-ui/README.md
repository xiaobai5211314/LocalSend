# Flutter UI 改造方案

## 概述

对 LocalSend Flutter 客户端 UI 进行改造，新增远程传输配置、设备列表区分、剪贴板同步状态指示和 URL 接力交互。

## 一、设置页改造

### 1.1 新增「远程传输」设置区块

位置：设置页 (`lib/pages/settings_page.dart`) 中「网络」分组后新增。

```dart
// 设置项定义
class RemoteTransferSettings {
  /// 是否启用远程传输（NAT 穿透 + 中继）
  bool enabled = false;

  /// 信令服务器地址 (WebSocket URL)
  String signalingServerUrl = 'ws://101.132.143.168:9000';

  /// TURN 服务器地址
  String turnServerUrl = 'turn:101.132.143.168:3478';

  /// TURN 认证用户名
  String turnUsername = '';

  /// TURN 认证密码
  String turnPassword = '';

  /// 远程传输超时时间（秒）
  int timeout = 30;
}
```

### 1.2 UI 布局设计

```
+------------------------------------------+
| Settings                                  |
+------------------------------------------+
| [Network]                                 |
|  Alias: [My Device              ]         |
|  Port:   [53317                  ]         |
+------------------------------------------+
| [Remote Transfer]              NEW        |
|  +--------------------------------------+ |
|  | Enable Remote Transfer    [switch]   | |
|  +--------------------------------------+ |
|  +--------------------------------------+ |
|  | Signaling Server                       |
|  | [ws://101.132.143.168:9000    ]       |
|  +--------------------------------------+ |
|  +--------------------------------------+ |
|  | TURN Server                            |
|  | [turn:101.132.143.168:3478    ]       |
|  +--------------------------------------+ |
|  +--------------------------------------+ |
|  | TURN Username                          |
|  | [localsend_user               ]       |
|  +--------------------------------------+ |
|  +--------------------------------------+ |
|  | TURN Password                          |
|  | [****************             ]       |
|  +--------------------------------------+ |
|  +--------------------------------------+ |
|  | Connection Status: Connected           |
|  | Server Latency: 23ms                   |
|  +--------------------------------------+ |
+------------------------------------------+
| [Clipboard Sync]               NEW       |
|  +--------------------------------------+ |
|  | Enable Clipboard Sync    [switch]    | |
|  +--------------------------------------+ |
|  | Sync mode: [Text only]  [Text + URL] | |
|  |            [All (incl. images)]      | |
|  +--------------------------------------+ |
|  | [x] Auto-open URLs on receive        | |
|  +--------------------------------------+ |
+------------------------------------------+
```

### 1.3 设置项持久化

使用 `shared_preferences` 存储配置：

```dart
class RemoteSettingsStorage {
  static const _keyEnabled = 'remote_transfer_enabled';
  static const _keySignalingUrl = 'signaling_server_url';
  static const _keyTurnUrl = 'turn_server_url';
  static const _keyTurnUser = 'turn_username';
  static const _keyTurnPass = 'turn_password';
  static const _keyClipboardSync = 'clipboard_sync_enabled';
  static const _keyClipboardMode = 'clipboard_sync_mode';
  static const _keyAutoOpenUrl = 'auto_open_url';

  Future<void> save(RemoteTransferSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, settings.enabled);
    await prefs.setString(_keySignalingUrl, settings.signalingServerUrl);
    await prefs.setString(_keyTurnUrl, settings.turnServerUrl);
    await prefs.setString(_keyTurnUser, settings.turnUsername);
    await prefs.setString(_keyTurnPass, settings.turnPassword);
    await prefs.setBool(_keyClipboardSync, settings.clipboardSyncEnabled);
    await prefs.setString(_keyClipboardMode, settings.clipboardSyncMode);
    await prefs.setBool(_keyAutoOpenUrl, settings.autoOpenUrl);
  }
}
```

## 二、设备列表页改造

### 2.1 区分局域网和远程设备

位置：`lib/pages/receive_page.dart` 或 `lib/widgets/device_list.dart`

```
+------------------------------------------+
| Devices                                   |
+------------------------------------------+
| [Local Network]                           |
| +--------------------------------------+ |
| | [icon] My-Desktop         192.168.1.5| |
| |       Available - Tap to send         | |
| +--------------------------------------+ |
| +--------------------------------------+ |
| | [icon] Living-Room-Phone  192.168.1.8| |
| |       Available - Tap to send         | |
| +--------------------------------------+ |
+------------------------------------------+
| [Remote Devices]              (via relay) |
| +--------------------------------------+ |
| | [globe] Office-PC       101.x.x.x    | |
| |         Online - 45ms latency         | |
| +--------------------------------------+ |
| +--------------------------------------+ |
| | [globe] Bob's-Phone      remote      | |
| |         Online - 120ms latency        | |
| +--------------------------------------+ |
+------------------------------------------+
```

### 2.2 设备列表数据模型

```dart
enum DeviceConnectionType {
  local,   // Same LAN, TCP direct
  remote,  // Different network, WebRTC/TURN
}

class RemoteDeviceInfo {
  final String deviceId;
  final String deviceName;
  final DeviceConnectionType connectionType;
  final String? ipAddress;
  final int? latencyMs;
  final bool isOnline;

  IconData get icon {
    switch (connectionType) {
      case DeviceConnectionType.local:
        return Icons.wifi;
      case DeviceConnectionType.remote:
        return Icons.public;
    }
  }

  String get subtitle {
    if (connectionType == DeviceConnectionType.remote) {
      return '${latencyMs ?? "?"}ms latency';
    }
    return ipAddress ?? 'Unknown';
  }
}
```

### 2.3 设备发现流程

```
Local Discovery (mDNS/SSDP):
  -> Periodic broadcast on LAN
  -> Populates "Local Network" section

Remote Discovery:
  -> WebSocket connect to signaling server
  -> Receive "device_list" message
  -> Populates "Remote Devices" section
  -> "device_left" message removes offline device
```

## 三、剪贴板同步状态指示

### 3.1 状态指示器 UI

在主界面 AppBar 或底部显示同步状态：

```
+------------------------------------------+
| LocalSend                    [sync icon] |
+------------------------------------------+

sync icon states:
  [green  circle] - Connected, actively syncing
  [yellow circle] - Connected, sync paused
  [gray   circle] - Disconnected
  [red    circle] - Error (tap for details)
  [pulse  anim  ] - Syncing data right now
```

### 3.2 状态指示器组件

```dart
class ClipboardSyncIndicator extends StatelessWidget {
  final SyncConnectionState state;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _tooltipMessage,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 300),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _indicatorColor,
        ),
        child: isSyncing
            ? CircularProgressIndicator(strokeWidth: 2)
            : null,
      ),
    );
  }

  Color get _indicatorColor {
    switch (state) {
      case SyncConnectionState.connected:
        return Colors.green;
      case SyncConnectionState.connecting:
        return Colors.orange;
      case SyncConnectionState.disconnected:
        return Colors.grey;
      case SyncConnectionState.error:
        return Colors.red;
    }
  }

  String get _tooltipMessage {
    switch (state) {
      case SyncConnectionState.connected:
        return 'Clipboard sync active';
      case SyncConnectionState.connecting:
        return 'Connecting...';
      case SyncConnectionState.disconnected:
        return 'Clipboard sync offline';
      case SyncConnectionState.error:
        return 'Sync error - tap for details';
    }
  }
}
```

## 四、URL 接力特殊处理

### 4.1 URL 接收流程

```
[Device A copies URL]
    |
    v
[ClipboardMonitor detects change]
    |
    v
[ClipboardSyncService sends update]
    |
    v
[Signaling Server relays to Device B]
    |
    v
[Device B ClipboardSyncService receives]
    |
    +---> Write URL to clipboard
    |
    +---> [if auto-open enabled] --> UrlRelayHandler.openUrl()
              |
              +---> http/https: Open in browser
              +---> market://: Open app store
              +---> intent://: Android Intent
              +---> Custom scheme: System handler
```

### 4.2 URL 接收通知

使用本地通知告知用户收到 URL：

```dart
class UrlRelayNotification {
  static Future<void> show(String url, String fromDevice) async {
    // Platform-specific notification
    // Android: Notification with "Open" action button
    // iOS: Local notification (limited to foreground)

    if (Platform.isAndroid) {
      // Use flutter_local_notifications
      const androidDetails = AndroidNotificationDetails(
        'url_relay_channel',
        'URL Relay',
        channelDescription: 'Notifications for received URLs',
        importance: Importance.high,
        priority: Priority.high,
        actions: [
          AndroidNotificationAction(
            'open_url',
            'Open',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            'dismiss',
            'Dismiss',
            cancelNotification: true,
          ),
        ],
      );
      // ... create notification
    }
  }
}
```

### 4.3 安全确认对话框

首次收到来自未知设备的 URL 时弹出确认：

```
+------------------------------------------+
| URL Relay                                 |
+------------------------------------------+
|                                           |
|  Office-PC sent a link:                   |
|                                           |
|  https://example.com/document.pdf         |
|                                           |
|  [Open in Browser]                        |
|  [Copy to Clipboard]                      |
|  [Ignore]                                 |
|                                           |
|  [ ] Always trust this device             |
+------------------------------------------+
```

## 五、依赖添加

在 `pubspec.yaml` 中新增：

```yaml
dependencies:
  web_socket_channel: ^2.4.0
  shared_preferences: ^2.2.0
  url_launcher: ^6.2.0
  flutter_local_notifications: ^16.0.0
  connectivity_plus: ^5.0.0
```

## 六、文件修改清单

| 文件 | 改动 | 说明 |
|------|------|------|
| `lib/pages/settings_page.dart` | 新增远程传输和剪贴板设置区块 | 设置 UI |
| `lib/widgets/device_list.dart` | 区分本地/远程设备分组 | 设备列表 |
| `lib/models/device.dart` | 新增 RemoteDeviceInfo 模型 | 数据模型 |
| `lib/services/remote_device_service.dart` | 新增信令服务器连接管理 | 远程设备发现 |
| `lib/services/clipboard_sync_service.dart` | 引用 clipboard-sync 模块 | 剪贴板同步 |
| `lib/widgets/clipboard_indicator.dart` | 新增同步状态指示器 | UI 组件 |
| `lib/widgets/url_relay_dialog.dart` | 新增 URL 接收确认弹窗 | 安全确认 |
| `pubspec.yaml` | 新增依赖 | 包管理 |
