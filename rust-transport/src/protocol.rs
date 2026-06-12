//! Signaling protocol message definitions for LocalSend transport layer.
//!
//! Defines all JSON message types exchanged between the Rust transport layer
//! and the WebSocket signaling server. These are the wire-format messages
//! used for device registration, SDP exchange, ICE candidate relay, and
//! transport mode negotiation.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ============================================================
// Message Envelope
// ============================================================

/// Top-level message envelope sent over the signaling channel.
/// All messages between client and signaling server use this wrapper.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalingMessage {
    /// Message type discriminator
    #[serde(rename = "type")]
    pub msg_type: String,
    /// Sender device ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// Target device ID (for directed messages)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    /// Message payload (type-specific)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
    /// Request ID for tracking request-response pairs
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    /// Error information (for error responses)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<SignalingError>,
    /// Server-assigned timestamp (Unix ms)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
}

impl SignalingMessage {
    /// Create a new message with the given type.
    pub fn new(msg_type: &str) -> Self {
        Self {
            msg_type: msg_type.to_string(),
            from: None,
            to: None,
            payload: None,
            request_id: None,
            error: None,
            timestamp: None,
        }
    }

    /// Set the sender device ID.
    pub fn with_from(mut self, from: &str) -> Self {
        self.from = Some(from.to_string());
        self
    }

    /// Set the target device ID.
    pub fn with_to(mut self, to: &str) -> Self {
        self.to = Some(to.to_string());
        self
    }

    /// Set a JSON payload.
    pub fn with_payload<T: Serialize>(mut self, payload: &T) -> serde_json::Result<Self> {
        self.payload = Some(serde_json::to_value(payload)?);
        Ok(self)
    }

    /// Set a request ID for correlation.
    pub fn with_request_id(mut self, id: &str) -> Self {
        self.request_id = Some(id.to_string());
        self
    }

    /// Set error information.
    pub fn with_error(mut self, code: i32, message: &str) -> Self {
        self.error = Some(SignalingError {
            code,
            message: message.to_string(),
        });
        self
    }

    /// Check if this is an error response.
    pub fn is_error(&self) -> bool {
        self.error.is_some()
    }

    /// Get the error code if present.
    pub fn error_code(&self) -> Option<i32> {
        self.error.as_ref().map(|e| e.code)
    }
}

// ============================================================
// Error
// ============================================================

/// Signaling error details.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalingError {
    /// Numeric error code
    pub code: i32,
    /// Human-readable error message
    pub message: String,
}

// ============================================================
// Message Type Constants
// ============================================================

/// Well-known signaling message types.
pub mod message_types {
    // --- Connection lifecycle ---
    /// Client -> Server: register device with signaling server
    pub const REGISTER: &str = "register";
    /// Server -> Client: registration acknowledgment
    pub const REGISTER_ACK: &str = "register_ack";
    /// Client -> Server: unregister device
    pub const UNREGISTER: &str = "unregister";
    /// Server -> Client: unregistration acknowledgment
    pub const UNREGISTER_ACK: &str = "unregister_ack";

    // --- Heartbeat ---
    /// Client <-> Server: heartbeat ping
    pub const PING: &str = "ping";
    /// Client <-> Server: heartbeat pong
    pub const PONG: &str = "pong";

    // --- Device discovery ---
    /// Client -> Server: request list of online devices
    pub const LIST_DEVICES: &str = "list_devices";
    /// Server -> Client: device list response
    pub const DEVICE_LIST: &str = "device_list";
    /// Server -> All: broadcast that a device joined
    pub const DEVICE_JOINED: &str = "device_joined";
    /// Server -> All: broadcast that a device left
    pub const DEVICE_LEFT: &str = "device_left";

    // --- ICE / WebRTC signaling ---
    /// Client -> Server -> Client: SDP offer
    pub const OFFER: &str = "offer";
    /// Client -> Server -> Client: SDP answer
    pub const ANSWER: &str = "answer";
    /// Client -> Server -> Client: ICE candidate
    pub const ICE_CANDIDATE: &str = "ice_candidate";
    /// Client -> Server -> Client: end-of-candidates signal
    pub const ICE_CANDIDATES_END: &str = "ice_candidates_end";

    // --- Transport negotiation ---
    /// Client -> Server -> Client: request transport mode (direct/relay)
    pub const TRANSPORT_REQUEST: &str = "transport_request";
    /// Client -> Server -> Client: transport mode response
    pub const TRANSPORT_RESPONSE: &str = "transport_response";
    /// Client -> Server -> Client: notify that relay is being used
    pub const RELAY_NOTIFY: &str = "relay_notify";

    // --- File transfer metadata ---
    /// Client -> Server -> Client: file transfer metadata
    pub const FILE_META: &str = "file_meta";
    /// Client -> Server -> Client: transfer acceptance
    pub const FILE_ACCEPT: &str = "file_accept";
    /// Client -> Server -> Client: transfer rejection
    pub const FILE_REJECT: &str = "file_reject";
    /// Client -> Server -> Client: transfer completion
    pub const FILE_COMPLETE: &str = "file_complete";
    /// Client -> Server -> Client: transfer cancelled
    pub const FILE_CANCEL: &str = "file_cancel";

    // --- Resume / retransmission ---
    /// Client -> Server -> Client: request specific chunks for resume
    pub const CHUNK_RESUME: &str = "chunk_resume";
    /// Client -> Server -> Client: acknowledge chunk resume request
    pub const CHUNK_RESUME_ACK: &str = "chunk_resume_ack";

    // --- Clipboard sync (forwarded to clipboard-sync module) ---
    /// Client -> Server -> Client: clipboard content relay
    pub const CLIPBOARD: &str = "clipboard";

    // --- Error ---
    /// Server -> Client: general error
    pub const ERROR: &str = "error";
}

// ============================================================
// Payload Types
// ============================================================

/// Device registration request payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterPayload {
    /// Unique device identifier
    pub device_id: String,
    /// Human-readable device name
    pub device_name: String,
    /// Device platform (e.g., "windows", "android", "ios")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// Device model string
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Protocol version supported
    #[serde(skip_serializing_if = "Option::is_none")]
    pub protocol_version: Option<u32>,
    /// Features bitmap (bit flags for supported capabilities)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub features: Option<u64>,
}

/// Feature flag bits for device capabilities.
pub mod feature_flags {
    pub const DIRECT_TRANSPORT: u64 = 1 << 0; // UDP hole punching
    pub const RELAY_TRANSPORT: u64 = 1 << 1; // TURN relay
    pub const CHUNKED_TRANSFER: u64 = 1 << 2; // Chunked file transfer
    pub const RESUME_SUPPORT: u64 = 1 << 3; // Breakpoint resume
    pub const CLIPBOARD_SYNC: u64 = 1 << 4; // Clipboard sharing
    pub const URL_RELAY: u64 = 1 << 5; // URL auto-open
}

/// Registration acknowledgment payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterAckPayload {
    /// Session token assigned by server
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_token: Option<String>,
    /// Server-assigned device ID (may be same as client's)
    pub device_id: String,
    /// Current server time
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_time: Option<u64>,
}

/// Device information as reported by the server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    /// Device ID
    pub device_id: String,
    /// Device name
    pub device_name: String,
    /// Platform
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// Model
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// IP address
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip_address: Option<String>,
    /// Whether the device is currently online
    pub online: bool,
    /// Time of last heartbeat (Unix ms)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<u64>,
    /// Supported features bitmap
    #[serde(skip_serializing_if = "Option::is_none")]
    pub features: Option<u64>,
}

/// Device list response payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceListPayload {
    /// List of online devices
    pub devices: Vec<DeviceInfo>,
}

/// SDP offer/answer payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SdpPayload {
    /// SDP string
    pub sdp: String,
    /// SDP type: "offer" or "answer"
    #[serde(rename = "type")]
    pub sdp_type: String,
}

/// ICE candidate payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IceCandidatePayload {
    /// SDP media stream ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sdp_mid: Option<String>,
    /// SDP media line index
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sdp_mline_index: Option<u32>,
    /// Candidate string (from SDP)
    pub candidate: String,
}

/// Transport negotiation request payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransportRequestPayload {
    /// Preferred transport mode: "direct" or "relay"
    pub mode: String,
    /// STUN binding result (public address)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_address: Option<String>,
    /// NAT type classification
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nat_type: Option<String>,
}

/// Transport negotiation response payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransportResponsePayload {
    /// Agreed transport mode
    pub mode: String,
    /// TURN relay address (if relay mode)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_address: Option<String>,
    /// TURN credentials (if relay mode)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_credentials: Option<RelayCredentials>,
}

/// TURN relay credentials.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayCredentials {
    /// TURN username
    pub username: String,
    /// TURN password
    pub password: String,
    /// TURN server address
    pub server: String,
    /// Allocation lifetime hint (seconds)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lifetime: Option<u32>,
}

/// File transfer metadata payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileMetaPayload {
    /// Transfer session ID
    pub transfer_id: String,
    /// File name
    pub file_name: String,
    /// File size in bytes
    pub file_size: u64,
    /// MIME type
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    /// Total number of chunks
    pub total_chunks: u32,
    /// Chunk size in bytes
    pub chunk_size: u32,
    /// SHA-256 hash of the complete file
    pub full_hash: String,
    /// Whether resume is available for this transfer
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_available: Option<bool>,
    /// Optional preview/thumbnail data (base64)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
}

/// Chunk resume request payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkResumePayload {
    /// Transfer session ID to resume
    pub transfer_id: String,
    /// List of missing chunk indices to retransmit
    pub missing_chunks: Vec<u32>,
}

/// Clipboard sync payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardPayload {
    /// Content hash for deduplication
    pub content_hash: String,
    /// MIME type of the clipboard content
    pub mime_type: String,
    /// Clipboard text content (for text/plain)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Base64-encoded binary content (for images, etc.)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    /// Whether this content contains a URL
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_url: Option<bool>,
    /// Detected URL if present
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Timestamp of clipboard capture (Unix ms)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
}

// ============================================================
// Error Codes
// ============================================================

/// Well-known error codes returned by the signaling server.
pub mod error_codes {
    /// General / unknown error
    pub const GENERAL_ERROR: i32 = 1000;
    /// Invalid message format
    pub const INVALID_MESSAGE: i32 = 1001;
    /// Device not registered
    pub const NOT_REGISTERED: i32 = 1002;
    /// Target device not found or offline
    pub const DEVICE_NOT_FOUND: i32 = 1003;
    /// Authentication failed
    pub const AUTH_FAILED: i32 = 1004;
    /// Rate limit exceeded
    pub const RATE_LIMITED: i32 = 1005;
    /// Transport mode negotiation failed
    pub const TRANSPORT_FAILED: i32 = 1006;
    /// Transfer rejected by remote peer
    pub const TRANSFER_REJECTED: i32 = 1007;
    /// Unsupported protocol version
    pub const UNSUPPORTED_VERSION: i32 = 1008;
    /// Server internal error
    pub const SERVER_ERROR: i32 = 2000;
}

// ============================================================
// Helpers
// ============================================================

/// Generate a random request ID.
pub fn generate_request_id() -> String {
    use rand::Rng;
    let id: u64 = rand::thread_rng().gen();
    format!("{:016x}", id)
}

/// Serialize a signaling message to JSON string.
pub fn serialize_message(msg: &SignalingMessage) -> serde_json::Result<String> {
    serde_json::to_string(msg)
}

/// Deserialize a signaling message from JSON bytes.
pub fn deserialize_message(data: &[u8]) -> serde_json::Result<SignalingMessage> {
    serde_json::from_slice(data)
}

/// Create a basic register message.
pub fn build_register(
    device_id: &str,
    device_name: &str,
    platform: Option<&str>,
    features: Option<u64>,
) -> SignalingMessage {
    let payload = RegisterPayload {
        device_id: device_id.to_string(),
        device_name: device_name.to_string(),
        platform: platform.map(|s| s.to_string()),
        model: None,
        protocol_version: Some(1),
        features,
    };

    SignalingMessage::new(message_types::REGISTER)
        .with_from(device_id)
        .with_payload(&payload)
        .unwrap_or_else(|_| SignalingMessage::new(message_types::REGISTER))
}

/// Create a heartbeat ping message.
pub fn build_ping(device_id: &str) -> SignalingMessage {
    SignalingMessage::new(message_types::PING)
        .with_from(device_id)
        .with_timestamp()
}

/// Create a heartbeat pong response.
pub fn build_pong(device_id: &str) -> SignalingMessage {
    SignalingMessage::new(message_types::PONG)
        .with_from(device_id)
        .with_timestamp()
}

/// Create an SDP offer/answer relay message.
pub fn build_sdp(
    sdp_type: &str,
    sdp: &str,
    from: &str,
    to: &str,
) -> SignalingMessage {
    let payload = SdpPayload {
        sdp: sdp.to_string(),
        sdp_type: sdp_type.to_string(),
    };

    SignalingMessage::new(if sdp_type == "offer" {
        message_types::OFFER
    } else {
        message_types::ANSWER
    })
    .with_from(from)
    .with_to(to)
    .with_payload(&payload)
    .unwrap_or_else(|_| SignalingMessage::new(message_types::OFFER))
}

/// Create an ICE candidate relay message.
pub fn build_ice_candidate(
    candidate: &str,
    sdp_mid: Option<&str>,
    sdp_mline_index: Option<u32>,
    from: &str,
    to: &str,
) -> SignalingMessage {
    let payload = IceCandidatePayload {
        sdp_mid: sdp_mid.map(|s| s.to_string()),
        sdp_mline_index,
        candidate: candidate.to_string(),
    };

    SignalingMessage::new(message_types::ICE_CANDIDATE)
        .with_from(from)
        .with_to(to)
        .with_payload(&payload)
        .unwrap_or_else(|_| SignalingMessage::new(message_types::ICE_CANDIDATE))
}

/// Create a file metadata notification message.
pub fn build_file_meta(
    transfer_id: &str,
    file_name: &str,
    file_size: u64,
    total_chunks: u32,
    chunk_size: u32,
    full_hash: &str,
    from: &str,
    to: &str,
) -> SignalingMessage {
    let payload = FileMetaPayload {
        transfer_id: transfer_id.to_string(),
        file_name: file_name.to_string(),
        file_size,
        mime_type: None,
        total_chunks,
        chunk_size,
        full_hash: full_hash.to_string(),
        resume_available: Some(true),
        preview: None,
    };

    SignalingMessage::new(message_types::FILE_META)
        .with_from(from)
        .with_to(to)
        .with_payload(&payload)
        .unwrap_or_else(|_| SignalingMessage::new(message_types::FILE_META))
}

// ============================================================
// Extensions
// ============================================================

impl SignalingMessage {
    /// Attach a timestamp to this message.
    fn with_timestamp(self) -> Self {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        Self {
            timestamp: Some(ts),
            ..self
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_roundtrip_register() {
        let msg = build_register("dev-001", "My Device", Some("windows"), Some(0x1F));
        let json = serialize_message(&msg).unwrap();
        let decoded = deserialize_message(json.as_bytes()).unwrap();
        assert_eq!(decoded.msg_type, message_types::REGISTER);
        assert_eq!(decoded.from, Some("dev-001".to_string()));
    }

    #[test]
    fn test_roundtrip_sdp() {
        let msg = build_sdp("offer", "v=0\r\n...", "dev-A", "dev-B");
        let json = serialize_message(&msg).unwrap();
        let decoded = deserialize_message(json.as_bytes()).unwrap();
        assert_eq!(decoded.msg_type, message_types::OFFER);
        assert_eq!(decoded.from, Some("dev-A".to_string()));
        assert_eq!(decoded.to, Some("dev-B".to_string()));
    }

    #[test]
    fn test_roundtrip_ice() {
        let msg = build_ice_candidate(
            "candidate:1 1 UDP 2130706431 192.168.1.5 53317 typ host",
            Some("0"),
            Some(0),
            "dev-A",
            "dev-B",
        );
        let json = serialize_message(&msg).unwrap();
        let decoded = deserialize_message(json.as_bytes()).unwrap();
        assert_eq!(decoded.msg_type, message_types::ICE_CANDIDATE);
    }

    #[test]
    fn test_error_message() {
        let msg = SignalingMessage::new(message_types::ERROR)
            .with_error(error_codes::DEVICE_NOT_FOUND, "Target device is offline");
        let json = serialize_message(&msg).unwrap();
        let decoded = deserialize_message(json.as_bytes()).unwrap();
        assert!(decoded.is_error());
        assert_eq!(decoded.error_code(), Some(error_codes::DEVICE_NOT_FOUND));
    }

    #[test]
    fn test_request_id() {
        let id = generate_request_id();
        assert_eq!(id.len(), 16);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_feature_flags() {
        let flags = feature_flags::DIRECT_TRANSPORT
            | feature_flags::CLIPBOARD_SYNC
            | feature_flags::URL_RELAY;
        assert_eq!(flags & feature_flags::DIRECT_TRANSPORT, feature_flags::DIRECT_TRANSPORT);
        assert_eq!(flags & feature_flags::RELAY_TRANSPORT, 0);
    }
}
