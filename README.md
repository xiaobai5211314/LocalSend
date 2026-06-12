# LocalSend Enhanced - 跨网络文件传输与设备协同平台

基于 [LocalSend](https://github.com/localsend/localsend) 的二开增强版本，突破局域网限制，新增 NAT 穿透、剪贴板同步、历史记录、文件夹自动同步、Web 端接收、多网卡优化等 6 大功能。

## 服务端

信令服务器 + TURN 中继均部署在阿里云 `101.132.143.168`。

## 已完成功能

| # | 功能 | 模块 | 说明 |
|---|------|------|------|
| 1 | NAT 穿透 / 中继模式 | `rust-transport/` `signaling-server/` `turn-server/` | STUN 打洞 + TURN 兜底，出差在外也能传文件 |
| 2 | 剪贴板同步 + URL 接力 | `clipboard-sync/` | 手机复制电脑自动收到，URL 自动识别并用对应 App 打开 |
| 3 | 历史记录 + 断点续传 | `transfer-history/` | SQLite 存储传输记录，一键重传；64KB 分块 + SHA256 校验断点续传 |
| 4 | 自动同步文件夹 | `folder-sync/` | 监视目录变化自动推送，类 Syncthing 体验 |
| 5 | Web 端 / 浏览器接收 | `web-receiver/` | 接收方无需装 App，浏览器打开链接直接下载，支持二维码分享 |
| 6 | 多网卡 / 热点优化 | `network-discovery/` | 全子网扫描 + 热点自动识别，解决手机热点的设备发现盲区 |

## 架构图

```
                        +-----------------+
                        |   TURN Server   |
                        |  (coturn:3478)  |
                        |  101.132.143.168|
                        +--------+--------+
                                 ^
                                 | Relay (fallback)
                                 |
+------------------+    +--------+--------+    +------------------+
|    Device A      |    | Signaling Server |    |    Device B      |
|  (Flutter App)   +<-->+  (Rust/WebSocket)+<-->+  (Flutter App)   |
|                  |    |   0.0.0.0:9000   |    |                  |
| +--------------+ |    +-----------------+ |    | +--------------+ |
| |Clipboard Sync| |                        |    | |Clipboard Sync| |
| |Folder Sync   | |                        |    | |Folder Sync   | |
| |Web Receiver  | |                        |    | |Web Receiver  | |
| |History       | |                        |    | |History       | |
| +--------------+ |                        |    | +--------------+ |
| |Rust Transport |<========= P2P ============>| |Rust Transport | |
| | (UDP Hole    | |      (direct UDP)        | | (UDP Hole    | |
| |  Punching)   | |                         | |  Punching)   | |
| +--------------+ |                         | +--------------+ |
+------------------+                         +------------------+

Protocol Flow:
  1. Device A/B register with Signaling Server via WebSocket
  2. Device A sends offer SDP -> Signaling -> Device B
  3. Device B sends answer SDP -> Signaling -> Device A
  4. ICE candidates exchanged via Signaling
  5. Attempt direct UDP hole punching (STUN)
  6. On failure, fallback to TURN relay
  7. File transfer / clipboard sync / folder sync over established channel
```

## 项目结构

```
LocalSend/
├── README.md
├── .gitignore
│
├── signaling-server/                  # Rust WebSocket 信令服务器
│   ├── Cargo.toml
│   ├── Dockerfile
│   └── src/main.rs                    # 设备注册 / SDP-ICE转发 / 心跳保活
│
├── turn-server/                       # TURN 中继服务器
│   ├── docker-compose.yml             # coturn 容器
│   └── turnserver.conf                # external-ip=101.132.143.168
│
├── rust-transport/                    # Rust NAT 穿透传输层
│   ├── Cargo.toml
│   ├── README.md
│   └── src/
│       ├── lib.rs                     # 模块入口
│       ├── stun_punch.rs              # STUN 绑定 + UDP 打洞
│       ├── relay.rs                   # TURN 中继回退 (3s 超时)
│       ├── chunked_transfer.rs        # 64KB 分块 + SHA256 + 断点续传
│       └── protocol.rs                # 信令协议定义
│
├── clipboard-sync/                    # 剪贴板同步 (Dart)
│   ├── pubspec.yaml
│   ├── README.md
│   └── lib/
│       ├── clipboard_sync.dart        # WebSocket 重连 / SHA256 去重 / 跨平台读写
│       └── url_relay.dart             # URL 识别 + 平台 App 自动打开
│
├── transfer-history/                  # 历史记录 + 断点续传 (Dart)
│   ├── pubspec.yaml
│   └── lib/
│       ├── models.dart                # TransferRecord 数据模型
│       ├── history_service.dart       # SQLite CRUD / 筛选 / 一键重传
│       ├── resume_manager.dart        # 断点续传状态管理
│       └── transfer_history.dart      # 已有实现
│
├── folder-sync/                       # 自动同步文件夹 (Dart)
│   ├── pubspec.yaml
│   └── lib/
│       ├── file_watcher.dart          # 递归监听 / 200ms 防抖 / 黑名单
│       └── folder_sync.dart           # 推送 / 冲突处理 / Hash 持久化
│
├── web-receiver/                      # Web 端接收 (Dart)
│   ├── pubspec.yaml
│   └── lib/
│       ├── web_receiver.dart          # HTTP 服务器 / Token / ZIP 打包
│       └── qrcode_gen.dart            # 二维码生成
│
├── network-discovery/                 # 多网卡 / 热点优化 (Dart)
│   ├── pubspec.yaml
│   └── lib/
│       ├── network_scanner.dart       # 全子网并行扫描 / 缓存
│       └── hotspot_detector.dart      # 热点网关指纹识别
│
├── integration/                       # 整合入口 + 测试
│   ├── pubspec.yaml
│   ├── lib/localsend_enhanced.dart    # EnhancedLocalSend 统一入口
│   └── test/                          # 7 个模块的单元测试
│       ├── localsend_enhanced_test.dart
│       ├── clipboard_sync_test.dart
│       ├── history_service_test.dart
│       ├── resume_manager_test.dart
│       ├── folder_sync_test.dart
│       ├── web_receiver_test.dart
│       └── network_scanner_test.dart
│
├── deploy/                            # 一键部署
│   ├── docker-compose.yml
│   ├── deploy.sh
│   └── env.example
│
└── flutter-ui/                        # Flutter UI 改造方案
    └── README.md
```

## 服务器部署

### 前提

- 服务器 IP: `101.132.143.168`
- 需要 Docker 和 Docker Compose
- 防火墙开放端口: `9000` (信令), `3478/tcp+udp` (TURN), `49152-65535` (TURN 数据通道)

### 一键部署

```bash
cd deploy/
cp env.example .env
# 编辑 .env 填入 TURN_USERNAME / TURN_PASSWORD
bash deploy.sh 101.132.143.168
```

或手动在服务器上：

```bash
cd deploy/
docker-compose up -d
```

## 本地构建

### Rust 模块

```bash
# 信令服务器
cd signaling-server/
cargo build --release

# 传输层（库）
cd rust-transport/
cargo build --release
```

### Dart 模块

各 Dart 包作为 LocalSend Flutter 项目的依赖引入：

```yaml
# 在 LocalSend 主项目的 pubspec.yaml 中添加本地依赖
dependencies:
  clipboard_sync:
    path: ../localsend-enhanced/clipboard-sync
  transfer_history:
    path: ../localsend-enhanced/transfer-history
  folder_sync:
    path: ../localsend-enhanced/folder-sync
  web_receiver:
    path: ../localsend-enhanced/web-receiver
  network_discovery:
    path: ../localsend-enhanced/network-discovery
```

## 信令服务器协议

### 消息格式

```json
{
  "type": "message_type",
  "from": "device_id",
  "to": "target_device_id",
  "payload": {}
}
```

### 消息类型

| Type | 方向 | 说明 |
|------|------|------|
| `register` | C->S | 设备注册，payload 含 device_name |
| `registered` | S->C | 注册成功，含 assigned device_id |
| `device_list` | S->C | 在线设备列表 |
| `request_device_list` | C->S | 请求设备列表 |
| `offer` | C<->C | WebRTC SDP Offer |
| `answer` | C<->C | WebRTC SDP Answer |
| `ice_candidate` | C<->C | ICE Candidate |
| `ping` | C<->S | 心跳 |
| `pong` | S->C | 心跳回复 |
| `clipboard_update` | C<->C | 剪贴板同步数据 |
| `device_left` | S->C | 设备离线通知 |

## 文件传输协议

分块传输，每块 64KB，带序号 (u32) + SHA256 校验，支持断点续传和按块重传。详细定义见 `rust-transport/src/protocol.rs`。

## License

本项目基于 LocalSend 项目进行二次开发，遵循其原始许可协议。
