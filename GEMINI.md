# LocalSend Enhanced 项目指南 (GEMINI.md)

欢迎来到 LocalSend Enhanced 项目工作区。本指南提供了该项目的核心架构、构建流程和开发约定的上下文信息，供 AI 助手（如 Gemini）和开发者在进行代码修改、测试和架构设计时参考。

## 1. 项目概述

LocalSend Enhanced 是基于 LocalSend 二次开发的增强版本，突破了原有的局域网限制。它引入了跨网络文件传输与设备协作平台的能力，新增了 6 大核心功能：
- **NAT 穿透 / 中继模式** (STUN/TURN)
- **剪贴板同步 + URL 接力**
- **历史记录 + 断点续传**
- **自动同步文件夹**
- **Web 端 / 浏览器接收**
- **多网卡 / 热点优化**

### 1.1 架构概览 (三层架构)
本项目是一个多语言的 Monorepo（单体仓库），主要分为以下三层：
1.  **客户端发现层 (局域网优先)**:
    *   **多网卡/热点发现 (`network-discovery/`)**: 依然保留且强化了原版 LocalSend 的局域网直连功能。通过 `NetworkScanner` 扫描本地所有子网（默认端口 53317），优先在局域网内建立 P2P 传输，没有完全“锁死”在云端。
2.  **服务器基础设施 (广域网扩展)**：
    *   **信令服务器 (`signaling-server/`)**: Rust 编写的 WebSocket 服务器。目前客户端的 `SignalingClient` 默认写死了 `ws://101.132.143.168:9000`，但底层架构（如 `EnhancedLocalSendConfig`）实际上支持动态传入。负责设备注册、SDP/ICE 中继、心跳等。
    *   **TURN 服务器 (`turn-server/`)**: 基于 coturn 的 Docker 容器部署 (端口 3478)，作为 P2P 失败时的 UDP/TCP 中继回退。
3.  **传输层 (`rust-transport/`)**:
    *   Rust 编写的 NAT 穿透传输层。负责 STUN UDP 打洞、TURN 中继回退、以及带有 SHA256 校验和断点续传的 64KB 分块文件传输。
4.  **Flutter 客户端 (`localsend_app/` 及各 Dart 模块)**:
    *   主应用位于 `localsend_app/`。
    *   独立功能包通过 `path` 依赖集成（位于 `clipboard-sync/`, `transfer-history/`, `folder-sync/`, `web-receiver/`, `network-discovery/`）。

## 2. 构建与运行指南

以下是各核心模块的常用命令。

### 2.1 Flutter 应用 (`localsend_app/`)
```bash
cd localsend_app
flutter pub get            # 安装依赖
flutter run                # 在连接的设备或模拟器上运行本地应用
flutter test               # 运行 Flutter 单元测试
flutter build apk          # 构建 Android APK
flutter build windows      # 构建 Windows 桌面应用
```

### 2.2 集成测试 (`integration/`)
用于测试各个独立 Dart 功能包的集成情况。
```bash
cd integration
dart test
```

### 2.3 Rust 模块 (服务器与传输层库)
```bash
# 信令服务器
cd signaling-server
cargo build --release
cargo test

# 传输层 (Rust 库)
cd rust-transport
cargo build --release
cargo test
```

### 2.4 服务器部署 (`deploy/`)
信令服务器和 TURN 服务器默认部署在 `101.132.143.168`。
```bash
cd deploy
cp env.example .env        # 需要配置 TURN_USERNAME 和 TURN_PASSWORD
bash deploy.sh 101.132.143.168
# 或手动使用 docker-compose: docker-compose up -d
```

## 3. 开发约定与规范

在进行代码修改时，请严格遵守以下约定：

### 3.1 代码风格与质量
*   **Dart/Flutter**:
    *   遵循 `localsend_app/analysis_options.yaml` 中定义的 lint 规则（基于 `flutter_lints`）。
    *   强制使用 `prefer_const_constructors`，尽可能使用 `const` 优化构建。
    *   采用 **Stream 响应式编程**：所有 Dart 后台服务应通过 `Stream<T>` 暴露状态或数据变更。
*   **Rust**:
    *   必须通过 `cargo clippy` 的标准检查，不能有警告。
    *   使用 `cargo fmt` 格式化代码。
    *   对于信令协议，采用 **Builder 模式** 构造消息（例如 `.with_from()`, `.with_payload()`）。

### 3.2 架构与设计原则
*   **模块解耦**: 新功能或复杂逻辑应尽可能封装在独立的 Dart 包中（类似于现有的 `folder-sync/` 等），并通过主应用中的门面模式（Facade）或事件总线（EventBus）进行通信，保持松耦合。
*   **连接级联容错机制 (LAN 优先)**:
    *   网络请求和 WebSocket 必须实现重试机制（如断线 3 秒自动重连）。
    *   传输策略必须遵循 **级联选择器** 模式：
        1.  **最高优先级**：局域网直连 (LAN P2P，基于 `network-discovery` 的 53317 端口扫描)。
        2.  **广域网尝试**：STUN UDP 打洞 (3秒超时)。
        3.  **最终兜底**：TURN 服务器中继。
*   **文件传输完整性**:
    *   大文件传输必须分片处理（目前设定为每块 64KB）。
    *   必须实现逐片 SHA-256 校验以及全文件哈希验证。
    *   传输状态必须持久化，以支持断点续传功能（基于 `transfer-history`）。

### 3.3 测试要求
*   **不可无测试提交**: 添加新特性或修复 Bug 时，必须在对应的 `test/` 目录下添加或更新单元测试。如果是涉及多模块协作的功能，应在 `integration/test/` 中补充集成测试。

---
*注：本文件旨在为 AI 代理和开发者提供项目上下文。修改关键架构或工作流规则时，请同步更新此文件以保持团队信息一致。*