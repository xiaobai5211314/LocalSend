# 剪贴板同步模块 (Clipboard Sync Module)

## 概述

实现 LocalSend 设备间的剪贴板内容实时同步。当用户在设备 A 复制内容后，设备 B 自动接收到该内容，并根据内容类型执行相应操作。

特别针对 **URL 接力** 场景：收到链接类型的剪贴板内容时，接收端自动使用浏览器或对应 App 打开该链接。

## 架构设计

```
+---------------------+          +---------------------+
|     Device A         |          |     Device B         |
|                      |          |                      |
| Clipboard Listener   |          | Clipboard Receiver   |
| (Platform Native)    |          | (Dart Service)       |
|      |               |          |      ^               |
|      v               |          |      |               |
| MethodChannel        |          | MethodChannel        |
|      |               |          |      |               |
|      v               |          |      |               |
| ClipboardSyncService |--WS----->| ClipboardSyncService |
| (Dart)               | Signaling| (Dart)               |
+---------------------+          +---------------------+
         |                                |
         +---------- Signaling -----------+
                   Server :9000
```

## 各平台剪贴板监听实现方案

### Android

使用 `ClipboardManager.addPrimaryClipChangedListener()` 监听剪贴板变化。
通过 Kotlin Method Channel 将变化通知 Dart 层。

```kotlin
// android/app/src/main/kotlin/.../ClipboardListenerPlugin.kt
class ClipboardListenerPlugin : MethodCallHandler, FlutterPlugin {
    private lateinit var clipboardManager: ClipboardManager
    private var eventSink: EventSink? = null

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startListening" -> startListening(result)
            "stopListening" -> stopListening()
        }
    }

    private fun startListening(result: Result) {
        clipboardManager.addPrimaryClipChangedListener {
            val clip = clipboardManager.primaryClip
            val item = clip?.getItemAt(0)
            val text = item?.text?.toString() ?: return@addPrimaryClipChangedListener
            eventSink?.success(mapOf("content" to text, "timestamp" to System.currentTimeMillis()))
        }
        result.success(null)
    }
}
```

### Windows

使用 Win32 API `AddClipboardFormatListener` 监听剪贴板变化。
注意：Windows 剪贴板监听需要消息循环，需在 `win32_window.cpp` 中注册。

```cpp
// windows/runner/clipboard_listener.cpp
#include <windows.h>

class ClipboardListener {
public:
    void StartListening(HWND hwnd) {
        AddClipboardFormatListener(hwnd);
    }

    // In WindowProc:
    // case WM_CLIPBOARDUPDATE:
    //     if (OpenClipboard(hwnd)) {
    //         HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    //         if (hData) {
    //             wchar_t* text = (wchar_t*)GlobalLock(hData);
    //             // Send text to Dart via MethodChannel
    //             GlobalUnlock(hData);
    //         }
    //         CloseClipboard();
    //     }
    //     break;
};
```

### iOS 限制说明

iOS 系统不提供剪贴板变化通知 API（`UIPasteboard` 无回调机制）。
替代方案：
- **轮询**：在 App 前台时以 1 秒间隔检查 `UIPasteboard.general.changeCount`
- **仅前台同步**：进入前台时触发一次剪贴板检查
- **通知用户限制**：在 iOS 端 UI 中说明剪贴板同步仅在前台有效

### macOS

使用 `NSPasteboard.general.changeCount` 结合定时器轮询。
macOS 同样无原生剪贴板变化通知，但可通过 `NSWorkspace` 的应用切换事件辅助触发。

## JSON 协议定义

### 剪贴板同步消息

```json
{
  "type": "clipboard_update",
  "from": "device_a_uuid",
  "to": "device_b_uuid",
  "payload": {
    "content_type": "text",
    "content": "Hello World",
    "timestamp": 1700000000000
  }
}
```

### content_type 枚举

| 值 | 说明 | 接收端行为 |
|----|------|-----------|
| `text` | 纯文本 | 写入剪贴板，显示通知 |
| `url` | URL 链接 | 写入剪贴板 + 自动打开浏览器 |
| `image` | 图片（Base64） | 压缩后写入剪贴板 |

## URL 接力流程

1. 用户在设备 A 复制一个 URL
2. Android/Windows 剪贴板监听器检测到变化
3. 通过 MethodChannel 通知 Dart 层
4. `ClipboardSyncService` 识别为 URL 类型
5. 通过信令服务器发送 `clipboard_update` (content_type=url) 到设备 B
6. 设备 B 的 `ClipboardSyncService` 收到消息
7. 调用 `url_launcher` 打开对应 App 或浏览器
8. 同时将 URL 写入设备 B 的剪贴板

## 安全考量

- 剪贴板同步需要用户在设置中明确开启
- 默认不启用，首次使用弹出隐私提示
- 可选择"仅同步 URL"模式（更安全）
- 信令服务器转发不存储剪贴板内容
- 端到端加密（可选扩展）：使用 WebRTC DataChannel 加密传输
