# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

LocalSend Enhanced（localsend_enhanced）—— 跨网络文件传输与设备协作平台，是 LocalSend 的二次增强版本。在局域网直传基础上新增 NAT 穿透、剪贴板同步、传输历史、文件夹自动同步、Web 端接收、多网卡网络优化等功能。

## 构建与测试命令

### Flutter 应用 (`localsend_app/`)
```bash
flutter pub get            # 安装依赖
flutter run                # 本地运行
flutter test               # 单元测试
flutter build apk          # Android 构建
flutter build windows      # Windows 构建
```

### 集成测试 (`integration/`)
```bash
cd integration/ && dart test
```

### Rust 信令服务器 (`signaling-server/`)
```bash
cargo build --release
cargo test
```

### Rust 传输库 (`rust-transport/`)
```bash
cargo build --release
cargo test
```

### 服务器部署 (`deploy/`)
```bash
cp deploy/env.example deploy/.env   # 配置 TURN_USERNAME、TURN_PASSWORD
bash deploy/deploy.sh <服务器IP>     # 一键部署：构建、上传、启动
# 或手动: cd deploy/ && docker-compose up -d
```

### 代码检查
- Dart：`localsend_app/analysis_options.yaml` — 引入 `flutter_lints`，强制 `prefer_const_constructors`
- Rust：标准 `cargo clippy` + `cargo fmt`

## 架构

三层架构：服务器基础设施、Rust 传输层、Flutter 客户端。

### 服务器基础设施
- **信令服务器** (`signaling-server/`) — Rust WebSocket 服务器（端口 9000），负责设备注册、SDP/ICE 中继、设备列表广播、心跳检测、剪贴板消息转发。使用 `tokio` + `tokio-tungstenite`。
- **TURN 服务器** (`turn-server/`) — coturn Docker 容器（端口 3478），当 P2P 直连失败时提供 UDP/TCP 中继回退，使用长期凭证认证。

### 传输层 (`rust-transport/`)
- `StunPunchTransport` — STUN 绑定请求发现公网地址、UDP 打洞（5 个错开探测包）、NAT 类型分类
- `RelayTransport` — TURN 中继分配、认证、权限管理、分配刷新
- `ChunkedTransfer` — 64KB 分片、逐片 SHA-256 校验、全文件哈希验证、断点续传（`ResumeInfo`）
- `protocol.rs` — 信令消息定义，Builder 模式（`.with_from()`、`.with_payload()`）

### Flutter 客户端 (`localsend_app/`)
4 个 Tab 页面（设备、传输、Web、设置）。核心模块：
- `signaling_client.dart` — WebSocket 客户端，断线自动重连（3 秒），15 秒心跳
- `clipboard_sync.dart` — 800ms 轮询剪贴板，SHA-256 去重
- `transfer_history.dart` — SQLite 单例模式，CRUD 操作
- `folder_sync.dart` — `DirectoryWatcher` 文件监听，200ms 防抖
- `web_receiver.dart` — 内嵌 HTTP 服务器，Token 认证，拖拽上传页面
- `network_discovery.dart` — 子网扫描（254 个 IP、200ms 超时）、热点检测

### 功能包（独立 Dart 包，通过 path 引用）
- `clipboard-sync/` — 跨平台剪贴板同步 + URL 中继
- `transfer-history/` — TransferRecord 模型、SQLite 服务、断点续传管理
- `folder-sync/` — 文件监听 + 文件夹同步与冲突处理
- `web-receiver/` — HTTP 服务器 + 二维码生成
- `network-discovery/` — 子网扫描器 + 热点检测器
- `integration/` — `EnhancedLocalSend` 统一门面，含 `EventBus` 和 `EnhancedLocalSendConfig`

### 连接流程
1. 通过 WebSocket 注册到信令服务器
2. 信令中继 SDP offer/answer 交换
3. 信令中继 ICE 候选者交换
4. 尝试 STUN UDP 打洞（3 秒超时）
5. 失败则回退到 TURN 中继
6. 通过建立的通道进行传输/同步

### 关键设计模式
- **EventBus** — 模块间松耦合通信
- **Stream 响应式** — 所有 Dart 服务暴露 `Stream<T>`
- **传输级联选择** — 局域网 TCP → STUN 打洞 → TURN 中继
- **分片传输与断点续传** — 64KB 分片、逐片 SHA-256、`ResumeInfo` 持久化状态
- **自动重连** — WebSocket 断开后自动重连
