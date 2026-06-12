//! TURN relay transport implementation.
//!
//! Provides TURN-based relay as a fallback when direct UDP hole punching fails.
//! Uses the TURN protocol (RFC 5766) to allocate a relay address and forward
//! traffic through the TURN server.
//!
//! # Flow
//! 1. Detect hole punch failure (timeout > 3 seconds)
//! 2. Connect to TURN server at configured address
//! 3. Allocate a relay address
//! 4. Create a permission for the remote peer
//! 5. Relay data through TURN

use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::time::timeout;
use turn::client::Client as TurnClient;
use turn::message::{AllocateRequest, RefreshRequest};

use crate::{IceConnectionState, TransportConfig, TransportError, TransportResult, TurnConfig};

/// Default TURN allocation lifetime in seconds.
const ALLOCATION_LIFETIME: u32 = 600; // 10 minutes

/// Refresh interval factor (refresh at 80% of lifetime).
const REFRESH_FACTOR: f64 = 0.8;

/// TURN relay transport.
///
/// Manages a TURN allocation for relaying data through a TURN server.
pub struct RelayTransport {
    /// TURN server configuration
    config: TurnConfig,
    /// TURN client instance
    client: Option<TurnClient>,
    /// Local UDP socket bound for TURN communication
    socket: Option<UdpSocket>,
    /// Allocated relay address on the TURN server
    relay_addr: Option<SocketAddr>,
    /// TURN server address
    server_addr: Option<SocketAddr>,
    /// ICE connection state
    ice_state: IceConnectionState,
    /// Nonce from TURN server for authentication
    nonce: Option<String>,
    /// Realm from TURN server
    realm: Option<String>,
    /// Whether a permission has been created for the peer
    peer_permission: bool,
}

impl RelayTransport {
    /// Create a new relay transport with TURN configuration.
    pub fn new(turn_config: TurnConfig) -> Self {
        Self {
            config: turn_config,
            client: None,
            socket: None,
            relay_addr: None,
            server_addr: None,
            ice_state: IceConnectionState::New,
            nonce: None,
            realm: None,
            peer_permission: false,
        }
    }

    /// Return the current ICE connection state.
    pub fn ice_state(&self) -> IceConnectionState {
        self.ice_state
    }

    /// Check if the relay is connected and ready.
    pub fn is_connected(&self) -> bool {
        self.ice_state == IceConnectionState::Connected && self.relay_addr.is_some()
    }

    /// Connect to the TURN server and allocate a relay address.
    ///
    /// This performs the full TURN allocation flow:
    /// 1. Send Allocate request (may get 401 with nonce/realm)
    /// 2. Authenticate with username/password (long-term credential)
    /// 3. Receive Allocate success response with relay address
    pub async fn allocate(&mut self) -> TransportResult<SocketAddr> {
        let server_addr: SocketAddr = self
            .config
            .server
            .parse()
            .map_err(|e| TransportError::TurnError(format!("Invalid TURN server address: {}", e)))?;

        self.server_addr = Some(server_addr);
        log::info!("Connecting to TURN server at {}", server_addr);

        // Bind local UDP socket
        let socket = UdpSocket::bind("0.0.0.0:0").await?;
        let local = socket.local_addr()?;
        log::debug!("TURN local socket bound to {}", local);

        // Build and send initial Allocate request
        let mut request = AllocateRequest::new();
        request.set_requested_transport(17); // UDP

        let request_bytes = request
            .encode()
            .map_err(|e| TransportError::TurnError(format!("Encode error: {}", e)))?;

        socket.send_to(&request_bytes, server_addr).await?;

        // Read response
        let mut buf = vec![0u8; 2048];
        let (n, _src) = timeout(Duration::from_secs(5), socket.recv_from(&mut buf))
            .await
            .map_err(|_| TransportError::Timeout)?
            .map_err(|e| TransportError::IoError(e))?;

        let response_bytes = &buf[..n];

        // Check if we got a 401 (Unauthenticated) with nonce + realm
        if is_stun_error(response_bytes, 401) {
            self.nonce = extract_attribute_str(response_bytes, 0x0015); // NONCE
            self.realm = extract_attribute_str(response_bytes, 0x0014); // REALM

            log::debug!(
                "TURN auth required: realm={}, nonce present={}",
                self.realm.as_deref().unwrap_or("?"),
                self.nonce.is_some()
            );

            // Build authenticated Allocate request
            let password = generate_keyed_md5(
                &self.config.username,
                self.realm.as_deref().unwrap_or(""),
                &self.config.password,
            );

            let mut auth_request = AllocateRequest::new();
            auth_request.set_requested_transport(17);
            auth_request.set_username(&self.config.username);
            auth_request.set_realm(self.realm.as_deref().unwrap_or(""));
            auth_request.set_nonce(self.nonce.as_deref().unwrap_or(""));
            auth_request.set_message_integrity(&password);

            let auth_bytes = auth_request
                .encode()
                .map_err(|e| TransportError::TurnError(format!("Encode auth error: {}", e)))?;

            socket.send_to(&auth_bytes, server_addr).await?;

            // Read authenticated response
            let mut buf2 = vec![0u8; 2048];
            let (n2, _) = timeout(Duration::from_secs(5), socket.recv_from(&mut buf2))
                .await
                .map_err(|_| TransportError::Timeout)?
                .map_err(|e| TransportError::IoError(e))?;

            // Parse relay address from success response
            let relay = extract_relay_address(&buf2[..n2])?;
            self.relay_addr = Some(relay);
            self.socket = Some(socket);
            self.ice_state = IceConnectionState::Connected;

            log::info!("TURN relay allocated: {}", relay);
            Ok(relay)
        } else {
            // Try to parse as successful response
            match extract_relay_address(response_bytes) {
                Ok(relay) => {
                    self.relay_addr = Some(relay);
                    self.socket = Some(socket);
                    self.ice_state = IceConnectionState::Connected;
                    log::info!("TURN relay allocated: {}", relay);
                    Ok(relay)
                }
                Err(e) => {
                    self.ice_state = IceConnectionState::Failed;
                    Err(e)
                }
            }
        }
    }

    /// Create a permission on the TURN server for a remote peer.
    ///
    /// A permission allows the TURN server to forward data from the
    /// peer's IP address to this allocation.
    pub async fn create_permission(&mut self, peer_addr: SocketAddr) -> TransportResult<()> {
        let socket = self
            .socket
            .as_ref()
            .ok_or(TransportError::TurnError("Not connected".into()))?;

        let server = self
            .server_addr
            .ok_or(TransportError::TurnError("No server address".into()))?;

        let password = generate_keyed_md5(
            &self.config.username,
            self.realm.as_deref().unwrap_or(""),
            &self.config.password,
        );

        let mut request = turn::message::CreatePermissionRequest::new();
        request.add_peer_address(peer_addr);
        request.set_username(&self.config.username);
        request.set_realm(self.realm.as_deref().unwrap_or(""));
        request.set_nonce(self.nonce.as_deref().unwrap_or(""));
        request.set_message_integrity(&password);

        let req_bytes = request
            .encode()
            .map_err(|e| TransportError::TurnError(format!("Encode error: {}", e)))?;

        socket.send_to(&req_bytes, server).await?;

        let mut buf = vec![0u8; 2048];
        let (n, _) = timeout(Duration::from_secs(5), socket.recv_from(&mut buf))
            .await
            .map_err(|_| TransportError::Timeout)?
            .map_err(|e| TransportError::IoError(e))?;

        if is_stun_success(&buf[..n]) {
            self.peer_permission = true;
            log::info!("TURN permission created for peer {}", peer_addr);
            Ok(())
        } else {
            Err(TransportError::TurnError(format!(
                "Permission creation failed for {}",
                peer_addr
            )))
        }
    }

    /// Send data to a peer through the TURN relay using Send Indication.
    pub async fn send_to_peer(
        &self,
        peer_addr: SocketAddr,
        data: &[u8],
    ) -> TransportResult<usize> {
        let socket = self
            .socket
            .as_ref()
            .ok_or(TransportError::TurnError("Not connected".into()))?;

        let server = self
            .server_addr
            .ok_or(TransportError::TurnError("No server address".into()))?;

        let password = generate_keyed_md5(
            &self.config.username,
            self.realm.as_deref().unwrap_or(""),
            &self.config.password,
        );

        let mut indication = turn::message::SendIndication::new();
        indication.set_peer_address(peer_addr);
        indication.set_data(data.to_vec());
        indication.set_username(&self.config.username);
        indication.set_realm(self.realm.as_deref().unwrap_or(""));
        indication.set_nonce(self.nonce.as_deref().unwrap_or(""));
        indication.set_message_integrity(&password);

        let bytes = indication
            .encode()
            .map_err(|e| TransportError::TurnError(format!("Encode error: {}", e)))?;

        let n = socket.send_to(&bytes, server).await?;
        Ok(n)
    }

    /// Receive data from a peer via TURN relay (Data Indication).
    pub async fn recv_from_peer(&self, buf: &mut [u8]) -> TransportResult<(usize, SocketAddr)> {
        let socket = self
            .socket
            .as_ref()
            .ok_or(TransportError::TurnError("Not connected".into()))?;

        let (n, src) = socket.recv_from(buf).await?;

        // Extract peer address and data from Data Indication
        let (peer_addr, data_len) = parse_data_indication(&buf[..n])?;

        // Copy data to the beginning of the buffer
        let data_start = n - data_len;
        buf.copy_within(data_start..n, 0);

        Ok((data_len, peer_addr))
    }

    /// Refresh the TURN allocation to keep it alive.
    pub async fn refresh(&mut self) -> TransportResult<()> {
        let socket = self
            .socket
            .as_ref()
            .ok_or(TransportError::TurnError("Not connected".into()))?;

        let server = self
            .server_addr
            .ok_or(TransportError::TurnError("No server address".into()))?;

        let password = generate_keyed_md5(
            &self.config.username,
            self.realm.as_deref().unwrap_or(""),
            &self.config.password,
        );

        let mut request = RefreshRequest::new();
        request.set_lifetime(ALLOCATION_LIFETIME);
        request.set_username(&self.config.username);
        request.set_realm(self.realm.as_deref().unwrap_or(""));
        request.set_nonce(self.nonce.as_deref().unwrap_or(""));
        request.set_message_integrity(&password);

        let req_bytes = request
            .encode()
            .map_err(|e| TransportError::TurnError(format!("Encode error: {}", e)))?;

        socket.send_to(&req_bytes, server).await?;
        log::trace!("TURN allocation refreshed");

        Ok(())
    }

    /// Close the relay transport and release the TURN allocation.
    pub async fn close(&mut self) {
        self.ice_state = IceConnectionState::Closed;
        // TURN allocation will expire naturally
        // Optionally send a Refresh with lifetime=0 to explicitly release
        self.socket = None;
        self.relay_addr = None;
    }
}

/// Detect whether hole punching has failed and TURN fallback is needed.
///
/// Returns true if the elapsed time exceeds the timeout and the
/// direct connection has not been established.
pub fn should_fallback_to_turn(
    elapsed_ms: u64,
    hole_punch_timeout_ms: u64,
    direct_connected: bool,
) -> bool {
    !direct_connected && elapsed_ms > hole_punch_timeout_ms
}

/// Check if a STUN/TURN message bytes represent a success response.
fn is_stun_success(bytes: &[u8]) -> bool {
    if bytes.len() < 2 {
        return false;
    }
    let msg_type = u16::from_be_bytes([bytes[0], bytes[1]]);
    // Success responses are in range 0x0100 - 0x01FF
    msg_type & 0x0110 == 0x0100
        || msg_type == 0x0103 // Allocate success
        || msg_type == 0x0108
}

// CreatePermission success
/// Check if bytes represent a STUN error response with the given code.
fn is_stun_error(bytes: &[u8], code: u16) -> bool {
    if bytes.len() < 2 {
        return false;
    }
    let msg_type = u16::from_be_bytes([bytes[0], bytes[1]]);
    msg_type & 0x0110 == 0x0110
        && bytes.len() > 20
        && {
            // Error code is in the ERROR-CODE attribute
            // Class is in the upper 3 bits, number in lower 8 bits
            let class = (bytes[22] & 0x07) as u16;
            let number = bytes[23] as u16;
            (class * 100 + number) == code
        }
}

/// Extract a string attribute value from TURN message bytes.
fn extract_attribute_str(bytes: &[u8], attr_type: u16) -> Option<String> {
    let mut pos = 20; // Skip STUN header (20 bytes)
    while pos + 4 <= bytes.len() {
        let typ = u16::from_be_bytes([bytes[pos], bytes[pos + 1]]);
        let len = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]) as usize;
        pos += 4;

        if typ == attr_type && pos + len <= bytes.len() {
            // Skip padding bytes
            return String::from_utf8(bytes[pos..pos + len])
                .ok()
                .map(|s| s.trim_end_matches('\0').to_string());
        }
        // Align to 4-byte boundary
        pos += (len + 3) & !3;
    }
    None
}

/// Extract the relayed address from an Allocate success response.
fn extract_relay_address(bytes: &[u8]) -> TransportResult<SocketAddr> {
    let mut pos = 20; // Skip STUN header
    while pos + 4 <= bytes.len() {
        let typ = u16::from_be_bytes([bytes[pos], bytes[pos + 1]]);
        let len = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]) as usize;
        pos += 4;

        if typ == 0x0016 && len >= 8 {
            // XOR-RELAYED-ADDRESS
            // Format: 1 byte reserved, 1 byte family, 2 bytes port, 4 bytes IP
            let family = bytes[pos + 1];
            let port = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]);
            let xor_port = port ^ 0x2112;

            if family == 0x01 {
                // IPv4
                let ip_octets = [
                    bytes[pos + 4] ^ 0x21,
                    bytes[pos + 5] ^ 0x12,
                    bytes[pos + 6] ^ 0xA4,
                    bytes[pos + 7] ^ 0x42,
                ];
                let ip = std::net::Ipv4Addr::from(ip_octets);
                return Ok(SocketAddr::new(std::net::IpAddr::V4(ip), xor_port));
            }
        } else if typ == 0x0005 && len >= 8 {
            // MAPPED-ADDRESS (plain, no XOR)
            let family = bytes[pos + 1];
            let port = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]);

            if family == 0x01 {
                let ip_octets = [bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]];
                let ip = std::net::Ipv4Addr::from(ip_octets);
                return Ok(SocketAddr::new(std::net::IpAddr::V4(ip), port));
            }
        }

        pos += (len + 3) & !3;
    }
    Err(TransportError::TurnError(
        "No relayed address in response".into(),
    ))
}

/// Parse a Data Indication message to extract the peer address and data length.
fn parse_data_indication(bytes: &[u8]) -> TransportResult<(SocketAddr, usize)> {
    let mut pos = 20;
    let mut peer_addr: Option<SocketAddr> = None;
    let mut data_offset = 0;
    let mut data_len = 0;

    while pos + 4 <= bytes.len() {
        let typ = u16::from_be_bytes([bytes[pos], bytes[pos + 1]]);
        let len = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]) as usize;
        pos += 4;

        if typ == 0x0012 && len >= 8 {
            // XOR-PEER-ADDRESS
            let family = bytes[pos + 1];
            let port = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]);
            let xor_port = port ^ 0x2112;

            if family == 0x01 {
                let ip_octets = [
                    bytes[pos + 4] ^ 0x21,
                    bytes[pos + 5] ^ 0x12,
                    bytes[pos + 6] ^ 0xA4,
                    bytes[pos + 7] ^ 0x42,
                ];
                let ip = std::net::Ipv4Addr::from(ip_octets);
                peer_addr = Some(SocketAddr::new(std::net::IpAddr::V4(ip), xor_port));
            }
        } else if typ == 0x0013 {
            // DATA
            data_offset = pos;
            data_len = len;
        }

        pos += (len + 3) & !3;
    }

    match peer_addr {
        Some(addr) => Ok((addr, data_len)),
        None => Err(TransportError::TurnError(
            "No peer address in Data Indication".into(),
        )),
    }
}

/// Generate keyed-MD5 password for TURN long-term credential mechanism.
fn generate_keyed_md5(username: &str, realm: &str, password: &str) -> String {
    use sha2::{Digest, Md5};
    let input = format!("{}:{}:{}", username, realm, password);
    let digest = Md5::digest(input.as_bytes());
    hex::encode(digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_should_fallback_to_turn() {
        // Within timeout, connected -> no fallback
        assert!(!should_fallback_to_turn(1000, 3000, true));
        // Within timeout, not connected -> no fallback yet
        assert!(!should_fallback_to_turn(1000, 3000, false));
        // Exceeded timeout, not connected -> fallback
        assert!(should_fallback_to_turn(4000, 3000, false));
        // Exceeded timeout, connected -> no fallback
        assert!(!should_fallback_to_turn(4000, 3000, true));
    }

    #[test]
    fn test_is_stun_success() {
        // Allocate success response type = 0x0103
        let bytes = vec![0x01, 0x03, 0x00, 0x00];
        assert!(is_stun_success(&bytes));

        // Error response
        let err = vec![0x01, 0x13, 0x00, 0x00];
        assert!(!is_stun_success(&err));
    }

    #[test]
    fn test_extract_mapped_address_basic() {
        // MAPPED-ADDRESS: type=0x0005, len=8, family=0x01, port=0x1F90, ip=127.0.0.1
        let mut header = vec![0x01, 0x03, 0x00, 0x00]; // message type + length placeholder
        header.extend_from_slice(&[0u8; 16]); // transaction ID placeholder
        header.push(0x00);
        header.push(0x05); // MAPPED-ADDRESS
        header.push(0x00);
        header.push(0x08); // length = 8
        header.push(0x00); // reserved
        header.push(0x01); // family = IPv4
        header.push(0x1F);
        header.push(0x90); // port = 8080
        header.extend_from_slice(&[127, 0, 0, 1]); // IP = 127.0.0.1

        let result = extract_relay_address(&header);
        assert!(result.is_ok());
        let addr = result.unwrap();
        assert_eq!(addr.port(), 8080);
        assert_eq!(addr.ip().to_string(), "127.0.0.1");
    }

    #[test]
    fn test_generate_keyed_md5() {
        let hash = generate_keyed_md5("user", "localsend", "pass");
        assert_eq!(hash.len(), 32); // MD5 hex = 32 chars
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
