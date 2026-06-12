# Rust 传输层改造方案 (Transport Layer Modifications)

## 概述

对 LocalSend 现有 Rust 传输层进行扩展，新增基于 WebRTC 的 UDP 打洞能力和 TURN 中继回退机制，使 LocalSend 支持跨 NAT 的远程文件传输。

## 文件规划

```
localsend_core/src/
|-- transport/
|   |-- mod.rs                    # 传输层入口，路由选择逻辑
|   |-- tcp_transport.rs          # (现有) 局域网 TCP 传输
|   |-- webrtc_module.rs          # (新增) WebRTC 封装与生命周期管理
|   `-- relay_transport.rs        # (新增) TURN 中继通道实现
```

## 一、UDP 打洞流程

### 流程概览

```
Device A                    Signaling Server              Device B
   |                             |                           |
   |-- register ---------------->|                           |
   |                             |<-- register --------------|
   |                             |                           |
   |-- Create PeerConnection     |                           |
   |-- Create Offer SDP -------->|                           |
   |                             |-- relay offer SDP ------>|
   |                             |                           |-- Create PeerConnection
   |                             |                           |-- Set Remote SDP (offer)
   |                             |                           |-- Create Answer SDP
   |                             |<-- relay answer SDP -----|
   |<-- relay answer SDP --------|                           |
   |-- Set Remote SDP (answer)   |                           |
   |                             |                           |
   |-- Gather ICE candidates --->|<-- Gather ICE candidates -|
   |  (via STUN)                 |  (via STUN)               |
   |                             |                           |
   |-- ICE candidate A1 -------->|                           |
   |                             |-- relay ICE A1 --------->|
   |                             |<-- relay ICE B1 ---------|
   |<-- relay ICE B1 ------------|                           |
   |                             |                           |
   |========== DIRECT UDP CONNECTION ESTABLISHED ===========|
   |                   (NAT Hole Punched)                    |
   |                                                         |
   |========== DataChannel (File Transfer) =================|
```

### STUN 交互

WebRTC ICE 框架内置 STUN 支持。使用 Google 公共 STUN 服务器：

```rust
// STUN server configuration
const STUN_SERVERS: &[&str] = &[
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
    "stun:stun2.l.google.com:19302",
];
```

### Candidate 交换

ICE candidates 通过信令服务器 WebSocket 中继：

```rust
#[derive(Serialize, Deserialize)]
struct IceCandidateMessage {
    sdp_mid: String,
    sdp_mline_index: u32,
    candidate: String,
}
```

### 连接建立检查

```
Gathering State: complete
  -> Check all candidate pairs
  -> If any pair succeeds: use direct P2P
  -> If all pairs fail: fallback to TURN relay
```

## 二、TURN 中继回退逻辑

### 回退决策树

```
                    +-----------------+
                    |  Start Transfer |
                    +--------+--------+
                             |
                    +--------v--------+
                    | Try Direct UDP  |
                    | (Hole Punching) |
                    +--------+--------+
                             |
                    +--------v--------+
                    | Connection OK?  |
                    +---+--------+----+
                        |        |
                     Yes|        |No (timeout 15s)
                        |        |
               +--------v-+   +--v----------------+
               | Use P2P  |   | Fallback to TURN  |
               | Channel  |   | Relay             |
               +----------+   +--+----------------+
                                  |
                          +-------v--------+
                          | Connect TURN   |
                          | 101.132.143.168|
                          | :3478          |
                          +-------+--------+
                                  |
                          +-------v--------+
                          | Allocate Relay |
                          | Address        |
                          +-------+--------+
                                  |
                          +-------v--------+
                          | Send via Relay |
                          | (All traffic   |
                          |  proxied)      |
                          +----------------+
```

### TURN 连接配置

```rust
pub struct TurnConfig {
    pub server: String,       // "101.132.143.168:3478"
    pub username: String,
    pub password: String,
    pub realm: String,        // "localsend"
}

pub struct RelayTransport {
    turn_config: TurnConfig,
    relay_connection: Option<RelayConnection>,
    allocated_address: Option<SocketAddr>,
}
```

### 性能考量

- TURN 中继带宽受限于服务器上行带宽
- 建议对 TURN 模式下的传输速率做限制（默认不超过服务器带宽的 80%）
- 大文件优先等待打洞成功；小文件（< 1MB）可直接走 TURN

## 三、与现有 TCP 传输的共存策略

```
                    TransportSelector
                           |
           +---------------+---------------+
           |               |               |
    +------v------+ +-----v------+ +------v------+
    | TCP (LAN)   | | WebRTC P2P | | TURN Relay  |
    | Priority: 1 | | Priority:2 | | Priority:3  |
    +-------------+ +------------+ +-------------+

Selection Logic:
  1. If device is on same subnet -> TCP (existing)
  2. If remote device + STUN success -> WebRTC P2P
  3. If remote device + STUN failed -> TURN Relay
```

### 传输选择器伪代码

```rust
impl TransportSelector {
    pub async fn select_transport(
        &self,
        target: &DeviceInfo,
        file_size: u64,
    ) -> Box<dyn Transport> {
        // Step 1: Check if same LAN
        if self.is_same_subnet(target) {
            return Box::new(TcpTransport::new(target));
        }

        // Step 2: Try UDP hole punching
        if let Some(peer_conn) = self.try_hole_punch(target).await {
            return Box::new(WebRtcTransport::new(peer_conn));
        }

        // Step 3: Fallback to TURN relay
        Box::new(RelayTransport::new(self.turn_config.clone(), target))
    }
}
```

## 四、文件分块传输适配

### 分块策略

```
File (N bytes)
  |
  +-- Chunk 0 (256 KB)
  +-- Chunk 1 (256 KB)
  +-- Chunk 2 (256 KB)
  +-- ...
  +-- Chunk K (remaining)

Chunk size: 256 KB (262144 bytes)
- Small enough for UDP MTU fragmentation avoidance
- Large enough to minimize overhead
- Aligned to 4KB page size for efficiency
```

### 分块消息格式

```rust
#[derive(Serialize, Deserialize)]
pub struct FileChunkMessage {
    pub transfer_id: String,     // Unique transfer session ID
    pub file_name: String,       // Original file name
    pub file_size: u64,          // Total file size in bytes
    pub chunk_index: u32,        // 0-based chunk index
    pub total_chunks: u32,       // Total number of chunks
    pub chunk_data: Vec<u8>,     // Raw chunk data (base64 in JSON)
    pub checksum: String,        // SHA-256 of chunk data
}

#[derive(Serialize, Deserialize)]
pub struct TransferCompleteMessage {
    pub transfer_id: String,
    pub file_name: String,
    pub total_chunks: u32,
    pub total_bytes: u64,
    pub full_checksum: String,  // SHA-256 of complete file
}
```

### 断点续传

```rust
#[derive(Serialize, Deserialize)]
pub struct TransferResumeRequest {
    pub transfer_id: String,
    pub received_chunks: Vec<u32>,  // List of successfully received chunk indices
    pub next_chunk: u32,            // Next expected chunk index
}

impl RelayTransport {
    /// Resume interrupted transfer by requesting only missing chunks.
    pub async fn resume_transfer(
        &mut self,
        resume_request: TransferResumeRequest,
    ) -> Result<(), TransportError> {
        // 1. Parse received_chunks to determine missing chunks
        // 2. Request only missing chunks from sender
        // 3. Assemble file from cached + newly received chunks
    }
}
```

## 五、现有代码集成方案

### webrtc_module.rs 接口设计

```rust
/// Represents a WebRTC-based peer connection for either
/// direct P2P or relayed communication.
pub struct WebRtcTransport {
    peer_connection: RTCPeerConnection,
    data_channel: RTCDataChannel,
    ice_connection_state: IceConnectionState,
    transfer_state: TransferState,
    config: WebRtcConfig,
}

pub struct WebRtcConfig {
    pub stun_servers: Vec<String>,
    pub turn_config: Option<TurnConfig>,
    pub ice_timeout_ms: u64,
    pub hole_punch_timeout_ms: u64,
    pub chunk_size: usize,           // 256 * 1024
    pub max_concurrent_chunks: u32,  // 4
}

impl WebRtcTransport {
    pub async fn new(config: WebRtcConfig) -> Result<Self, WebRtcError>;

    /// Start as offerer (initiating device)
    pub async fn create_offer(&mut self) -> Result<SdpMessage, WebRtcError>;

    /// Start as answerer (receiving device)
    pub async fn create_answer(
        &mut self,
        offer: SdpMessage,
    ) -> Result<SdpMessage, WebRtcError>;

    /// Add remote ICE candidate
    pub async fn add_ice_candidate(
        &mut self,
        candidate: IceCandidateMessage,
    ) -> Result<(), WebRtcError>;

    /// Check if direct connection succeeded
    pub fn is_direct_connection(&self) -> bool;

    /// Get current ICE connection state
    pub fn ice_state(&self) -> IceConnectionState;

    /// Send file with chunking
    pub async fn send_file(
        &mut self,
        file_path: &Path,
        progress_callback: Option<Box<dyn Fn(f64)>>,
    ) -> Result<(), WebRtcError>;

    /// Receive file with chunk assembly
    pub async fn receive_file(
        &mut self,
        output_dir: &Path,
        progress_callback: Option<Box<dyn Fn(f64)>>,
    ) -> Result<PathBuf, WebRtcError>;
}
```

### relay_transport.rs 接口设计

```rust
pub struct RelayTransport {
    turn_client: TurnClient,
    allocated_addr: Option<SocketAddr>,
    peer_addr: Option<SocketAddr>,
    channel: Option<RelayChannel>,
    config: TurnConfig,
}

impl RelayTransport {
    /// Allocate a relay address on the TURN server.
    pub async fn allocate(&mut self) -> Result<SocketAddr, RelayError>;

    /// Create a permission for a remote peer.
    pub async fn create_permission(
        &mut self,
        peer_addr: SocketAddr,
    ) -> Result<(), RelayError>;

    /// Send data to the peer via TURN relay.
    pub async fn send(&mut self, data: &[u8]) -> Result<usize, RelayError>;

    /// Receive data from the peer via TURN relay.
    pub async fn recv(&mut self, buf: &mut [u8]) -> Result<usize, RelayError>;

    /// Send a channel-bound data packet.
    pub async fn send_channel_data(
        &mut self,
        channel_number: u16,
        data: &[u8],
    ) -> Result<usize, RelayError>;
}
```

## 六、依赖项

在 LocalSend 现有 `Cargo.toml` 中新增：

```toml
[dependencies]
# WebRTC (using webrtc-rs)
webrtc = "0.9"
webrtc-ice = "0.9"
webrtc-data = "0.8"

# TURN client
turn-rs = "0.7"

# Async runtime (already in use)
tokio = { version = "1", features = ["full"] }

# Serialization (already in use)
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# SHA-256 for chunk checksum
sha2 = "0.10"
hex = "0.4"

# Base64 for data encoding in signaling messages
base64 = "0.21"
```

## 七、测试策略

| 测试场景 | 方法 | 预期结果 |
|---------|------|---------|
| LAN 内 TCP 传输 | 两台同网段设备 | TCP 直连，速度正常 |
| NAT 打洞成功 | 两台不同 NAT 设备 | WebRTC P2P 直连 |
| 对称 NAT 打洞失败 | 两台对称 NAT 设备 | 自动回退 TURN |
| 大文件分块 | > 100MB 文件传输 | 分块正确，校验通过 |
| 断点续传 | 传输中断后重连 | 从断点继续，不重传已完成块 |
| TURN 认证失败 | 错误密码 | 返回明确错误，不卡死 |
| ICE 超时 | 网络不通 | 15 秒超时后触发 TURN 回退 |
