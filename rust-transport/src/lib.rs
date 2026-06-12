//! LocalSend Transport Layer
//!
//! Provides NAT traversal (STUN hole punching + TURN relay fallback) and
//! chunked file transfer with SHA-256 checksums and resume support.
//!
//! # Architecture
//! ```text
//! TransportSelector
//!   ├── StunPunchTransport  (UDP hole punching via STUN)
//!   ├── RelayTransport      (TURN relay fallback)
//!   └── ChunkedTransfer     (file chunking + checksums + resume)
//! ```

pub mod chunked_transfer;
pub mod protocol;
pub mod relay;
pub mod stun_punch;

use std::net::SocketAddr;
use std::path::PathBuf;
use thiserror::Error;

/// Errors that can occur during transport operations.
#[derive(Error, Debug)]
pub enum TransportError {
    #[error("STUN error: {0}")]
    StunError(String),

    #[error("TURN error: {0}")]
    TurnError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Connection timeout")]
    Timeout,

    #[error("Checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },

    #[error("Transfer already complete")]
    AlreadyComplete,

    #[error("Invalid chunk index: {0}")]
    InvalidChunk(usize),

    #[error("Signaling error: {0}")]
    SignalingError(String),

    #[error("{0}")]
    Other(String),
}

/// Result type alias for transport operations.
pub type TransportResult<T> = Result<T, TransportError>;

/// ICE connection state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IceConnectionState {
    New,
    Checking,
    Connected,
    Completed,
    Failed,
    Disconnected,
    Closed,
}

/// Transfer session state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferState {
    Idle,
    Connecting,
    InProgress,
    Paused,
    Completed,
    Failed,
}

/// Transport channel configuration.
#[derive(Debug, Clone)]
pub struct TransportConfig {
    /// STUN server addresses (e.g., "stun.l.google.com:19302")
    pub stun_servers: Vec<String>,
    /// TURN server configuration (optional)
    pub turn_config: Option<TurnConfig>,
    /// ICE connection timeout in milliseconds
    pub ice_timeout_ms: u64,
    /// Hole punch timeout in milliseconds
    pub hole_punch_timeout_ms: u64,
    /// File chunk size in bytes (default: 65536 = 64KB)
    pub chunk_size: usize,
    /// Max number of concurrent chunk transmissions
    pub max_concurrent_chunks: u32,
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            stun_servers: vec![
                "stun.l.google.com:19302".to_string(),
                "stun1.l.google.com:19302".to_string(),
            ],
            turn_config: None,
            ice_timeout_ms: 15_000,
            hole_punch_timeout_ms: 3_000,
            chunk_size: 65536, // 64 KB
            max_concurrent_chunks: 4,
        }
    }
}

/// TURN server configuration.
#[derive(Debug, Clone)]
pub struct TurnConfig {
    /// TURN server address (e.g., "101.132.143.168:3478")
    pub server: String,
    /// Authentication username
    pub username: String,
    /// Authentication password
    pub password: String,
    /// Authentication realm
    pub realm: String,
}

/// Information about a discovered peer.
#[derive(Debug, Clone)]
pub struct PeerInfo {
    /// Unique device identifier
    pub device_id: String,
    /// Human-readable device name
    pub device_name: String,
    /// Peer's public IP address (from STUN)
    pub public_addr: Option<SocketAddr>,
    /// Peer's local IP address
    pub local_addr: Option<SocketAddr>,
}

/// Transport mode selection result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportMode {
    /// Direct UDP hole-punched connection
    Direct,
    /// TURN relay fallback
    Relay,
}
