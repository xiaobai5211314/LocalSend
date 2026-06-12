//! STUN-based NAT traversal and UDP hole punching.
//!
//! Implements:
//! - STUN binding request to discover public address
//! - ICE candidate generation
//! - Simultaneous UDP hole punching (both sides send packets to the peer's
//!   public address to create NAT bindings)

use std::net::{SocketAddr, UdpSocket};
use std::time::Duration;

use rand::Rng;
use stun::client::Client as StunClient;
use stun::message::{Message, BINDING_REQUEST};
use tokio::net::UdpSocket as TokioUdpSocket;
use tokio::time::{sleep, timeout};

use crate::{IceConnectionState, PeerInfo, TransportConfig, TransportError, TransportResult};

/// Default STUN server port.
const DEFAULT_STUN_PORT: u16 = 3478;

/// Magic cookie for STUN messages (RFC 5389).
const STUN_MAGIC_COOKIE: u32 = 0x2112A442;

/// Result of a STUN binding request.
#[derive(Debug, Clone)]
pub struct StunBindingResult {
    /// Public IP address as seen by the STUN server
    pub public_addr: SocketAddr,
    /// Local address used for the binding request
    pub local_addr: SocketAddr,
    /// NAT type classification (simplified)
    pub nat_type: NatType,
}

/// Simplified NAT type classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NatType {
    /// Full Cone NAT or no NAT (direct mapping)
    FullCone,
    /// Restricted Cone NAT
    RestrictedCone,
    /// Port Restricted Cone NAT
    PortRestrictedCone,
    /// Symmetric NAT (hard to punch)
    SymmetricNat,
    /// Unknown / could not determine
    Unknown,
}

impl std::fmt::Display for NatType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NatType::FullCone => write!(f, "FullCone"),
            NatType::RestrictedCone => write!(f, "RestrictedCone"),
            NatType::PortRestrictedCone => write!(f, "PortRestrictedCone"),
            NatType::SymmetricNat => write!(f, "SymmetricNat"),
            NatType::Unknown => write!(f, "Unknown"),
        }
    }
}

/// ICE candidate as defined in RFC 5245.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct IceCandidate {
    /// Foundation: identifier for the candidate
    pub foundation: String,
    /// Component ID (1 for RTP, 2 for RTCP)
    pub component: u32,
    /// Transport protocol ("udp" or "tcp")
    pub transport: String,
    /// Priority value
    pub priority: u32,
    /// IP address
    pub address: String,
    /// Port number
    pub port: u16,
    /// Candidate type: "host", "srflx", "relay"
    #[serde(rename = "type")]
    pub candidate_type: String,
    /// Related address for server-reflexive candidates
    pub related_address: Option<String>,
    /// Related port for server-reflexive candidates
    pub related_port: Option<u16>,
    /// SDP media stream ID ("mid")
    pub sdp_mid: Option<String>,
    /// SDP media line index
    pub sdp_mline_index: Option<u32>,
}

impl IceCandidate {
    /// Generate a host candidate from a local address.
    pub fn host_candidate(addr: SocketAddr) -> Self {
        IceCandidate {
            foundation: format!("host-{}", rand::thread_rng().gen::<u32>()),
            component: 1,
            transport: "udp".to_string(),
            priority: 126 | 2122260223, // type=host=126, local pref=65535, component=1
            address: addr.ip().to_string(),
            port: addr.port(),
            candidate_type: "host".to_string(),
            related_address: None,
            related_port: None,
            sdp_mid: Some("0".to_string()),
            sdp_mline_index: Some(0),
        }
    }

    /// Generate a server-reflexive candidate from a STUN binding result.
    pub fn srflx_candidate(public: SocketAddr, local: SocketAddr) -> Self {
        IceCandidate {
            foundation: format!("srflx-{}", rand::thread_rng().gen::<u32>()),
            component: 1,
            transport: "udp".to_string(),
            priority: 100 | 2122260223,
            address: public.ip().to_string(),
            port: public.port(),
            candidate_type: "srflx".to_string(),
            related_address: Some(local.ip().to_string()),
            related_port: Some(local.port()),
            sdp_mid: Some("0".to_string()),
            sdp_mline_index: Some(0),
        }
    }
}

/// Main STUN punch transport handler.
pub struct StunPunchTransport {
    config: TransportConfig,
    local_socket: Option<TokioUdpSocket>,
    local_addr: Option<SocketAddr>,
    public_addr: Option<SocketAddr>,
    peer_addr: Option<SocketAddr>,
    ice_state: IceConnectionState,
    nat_type: Option<NatType>,
}

impl StunPunchTransport {
    /// Create a new STUN punch transport instance.
    pub fn new(config: TransportConfig) -> Self {
        Self {
            config,
            local_socket: None,
            local_addr: None,
            public_addr: None,
            peer_addr: None,
            ice_state: IceConnectionState::New,
            nat_type: None,
        }
    }

    /// Return the current ICE connection state.
    pub fn ice_state(&self) -> IceConnectionState {
        self.ice_state
    }

    /// Return the discovered public address (after STUN binding).
    pub fn public_addr(&self) -> Option<SocketAddr> {
        self.public_addr
    }

    /// Return the NAT type (after classification).
    pub fn nat_type(&self) -> Option<NatType> {
        self.nat_type
    }

    /// Perform a STUN binding request to discover the public address.
    ///
    /// Binds a local UDP socket and sends a BINDING_REQUEST to the STUN server.
    /// The response contains the public (mapped) address.
    pub async fn discover_public_addr(
        &mut self,
        stun_server: &str,
    ) -> TransportResult<StunBindingResult> {
        log::info!("Performing STUN binding request to {}", stun_server);

        // Parse STUN server address
        let stun_addr: SocketAddr = parse_stun_addr(stun_server)?;

        // Bind local UDP socket
        let local_socket = TokioUdpSocket::bind("0.0.0.0:0").await?;
        let local_addr = local_socket.local_addr()?;
        self.local_addr = Some(local_addr);
        log::debug!("Local UDP socket bound to {}", local_addr);

        // Build STUN binding request
        let mut msg = Message::new();
        msg.set_type(BINDING_REQUEST);
        let transaction_id = rand::thread_rng().gen::<[u8; 12]>();
        msg.set_transaction_id(transaction_id);

        let mut buf = vec![0u8; 256];
        let n = {
            let mut encoder = stun::message::MessageEncoder::default();
            encoder
                .encode(&mut buf, &msg)
                .map_err(|e| TransportError::StunError(format!("Encode error: {}", e)))?
        };
        buf.truncate(n);

        // Send binding request to STUN server
        local_socket.send_to(&buf, stun_addr).await?;
        log::debug!("STUN binding request sent to {}", stun_addr);

        // Receive response with timeout
        let mut recv_buf = vec![0u8; 2048];
        let recv_result = timeout(
            Duration::from_millis(self.config.hole_punch_timeout_ms),
            local_socket.recv_from(&mut recv_buf),
        )
        .await
        .map_err(|_| TransportError::Timeout)?
        .map_err(|e| TransportError::IoError(e))?;

        let (n_read, _src_addr) = recv_result;
        recv_buf.truncate(n_read);

        // Decode STUN response and extract mapped address
        let response = {
            let mut decoder = stun::message::MessageDecoder::default();
            decoder
                .decode(&recv_buf)
                .map_err(|e| TransportError::StunError(format!("Decode error: {}", e)))?
        };

        let public_addr = extract_mapped_address(&response)?;
        log::info!(
            "STUN binding successful: public addr = {}, local addr = {}",
            public_addr,
            local_addr
        );

        self.public_addr = Some(public_addr);
        self.local_socket = Some(local_socket);
        self.ice_state = IceConnectionState::Checking;

        // Classify NAT type (simplified heuristic)
        let nat_type = classify_nat(local_addr, public_addr);
        self.nat_type = Some(nat_type);
        log::info!("NAT type classified as: {}", nat_type);

        Ok(StunBindingResult {
            public_addr,
            local_addr,
            nat_type,
        })
    }

    /// Attempt UDP hole punching by sending probe packets to the peer.
    ///
    /// Both sides send packets simultaneously to create NAT bindings.
    /// On FullCone NAT, a single packet suffices. On more restrictive NATs,
    /// multiple packets are sent with small delays.
    pub async fn punch_hole(
        &mut self,
        peer_public_addr: SocketAddr,
    ) -> TransportResult<()> {
        log::info!(
            "Attempting UDP hole punch to peer at {}",
            peer_public_addr
        );

        self.peer_addr = Some(peer_public_addr);

        let socket = self
            .local_socket
            .as_ref()
            .ok_or(TransportError::Other("Socket not initialized".into()))?;

        let punch_payload = b"LOCALSEND_PUNCH";
        let mut success = false;

        // Send multiple punch packets with staggered timing for reliability
        for i in 0..5u32 {
            let mut packet = vec![0u8; 4 + punch_payload.len()];
            packet[0..4].copy_from_slice(&i.to_be_bytes());
            packet[4..].copy_from_slice(punch_payload);

            socket.send_to(&packet, peer_public_addr).await?;
            log::trace!("Punch packet {} sent to {}", i, peer_public_addr);

            // Listen briefly for a response
            let mut recv_buf = vec![0u8; 1024];
            let recv = timeout(
                Duration::from_millis(500),
                socket.recv_from(&mut recv_buf),
            )
            .await;

            if let Ok(Ok((n, src))) = recv {
                if src == peer_public_addr && n > 0 {
                    log::info!(
                        "Hole punch successful: received response from {}",
                        src
                    );
                    success = true;
                    break;
                }
            }

            // Small delay between attempts
            sleep(Duration::from_millis(200)).await;
        }

        if success {
            self.ice_state = IceConnectionState::Connected;
            Ok(())
        } else {
            self.ice_state = IceConnectionState::Failed;
            Err(TransportError::Timeout)
        }
    }

    /// Generate ICE candidates for signaling exchange.
    pub fn generate_candidates(&self) -> Vec<IceCandidate> {
        let mut candidates = Vec::new();

        // Host candidate
        if let Some(local) = self.local_addr {
            candidates.push(IceCandidate::host_candidate(local));
        }

        // Server-reflexive candidate
        if let (Some(public), Some(local)) = (self.public_addr, self.local_addr) {
            candidates.push(IceCandidate::srflx_candidate(public, local));
        }

        candidates
    }

    /// Send raw data over the punched connection.
    pub async fn send(&self, data: &[u8]) -> TransportResult<usize> {
        let socket = self
            .local_socket
            .as_ref()
            .ok_or(TransportError::Other("Socket not initialized".into()))?;

        let peer = self
            .peer_addr
            .ok_or(TransportError::Other("Peer address not set".into()))?;

        let n = socket.send_to(data, peer).await?;
        Ok(n)
    }

    /// Receive raw data from the punched connection.
    pub async fn recv(&self, buf: &mut [u8]) -> TransportResult<(usize, SocketAddr)> {
        let socket = self
            .local_socket
            .as_ref()
            .ok_or(TransportError::Other("Socket not initialized".into()))?;

        let (n, addr) = socket.recv_from(buf).await?;
        Ok((n, addr))
    }

    /// Check if a direct connection has been established.
    pub fn is_connected(&self) -> bool {
        self.ice_state == IceConnectionState::Connected
    }

    /// Close the transport.
    pub fn close(&mut self) {
        self.ice_state = IceConnectionState::Closed;
        self.local_socket = None;
    }
}

/// Parse a STUN server address string into a SocketAddr.
fn parse_stun_addr(server: &str) -> TransportResult<SocketAddr> {
    // Handle "stun:" prefix from WebRTC config
    let addr_str = server
        .strip_prefix("stun:")
        .unwrap_or(server);

    addr_str
        .parse::<SocketAddr>()
        .or_else(|_| {
            // Try with default STUN port
            format!("{}:{}", addr_str, DEFAULT_STUN_PORT).parse()
        })
        .map_err(|e| {
            TransportError::StunError(format!("Invalid STUN server address '{}': {}", server, e))
        })
}

/// Extract the XOR-MAPPED-ADDRESS or MAPPED-ADDRESS from a STUN response.
fn extract_mapped_address(msg: &Message) -> TransportResult<SocketAddr> {
    // Try XOR-MAPPED-ADDRESS first (RFC 5389)
    for attr in msg.attributes() {
        match attr.get_type() {
            stun::attribute::ATTR_XOR_MAPPED_ADDRESS => {
                if let Ok(addr) = attr.get_xor_mapped_address() {
                    return Ok(addr);
                }
            }
            stun::attribute::ATTR_MAPPED_ADDRESS => {
                if let Ok(addr) = attr.get_mapped_address() {
                    return Ok(addr);
                }
            }
            _ => {}
        }
    }
    Err(TransportError::StunError(
        "No mapped address in STUN response".into(),
    ))
}

/// Classify NAT type based on local and public address comparison.
///
/// This is a simplified heuristic. A full NAT type detection requires
/// sending STUN requests to multiple servers and ports (RFC 5780).
fn classify_nat(local: SocketAddr, public: SocketAddr) -> NatType {
    // If local IP matches public IP, likely no NAT (or FullCone)
    if local.ip() == public.ip() {
        NatType::FullCone
    } else if local.port() == public.port() {
        // Same port suggests FullCone (endpoint-independent mapping)
        NatType::FullCone
    } else {
        // Port changed, likely restricted or symmetric
        // Conservative default: assume PortRestrictedCone
        NatType::PortRestrictedCone
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_stun_addr() {
        // With stun: prefix
        let addr = parse_stun_addr("stun:stun.l.google.com:19302");
        assert!(addr.is_ok());

        // Without prefix
        let addr = parse_stun_addr("1.2.3.4:3478");
        assert!(addr.is_ok());

        // Without port (should use default)
        let addr = parse_stun_addr("stun.l.google.com");
        assert!(addr.is_ok());
    }

    #[test]
    fn test_ice_candidate_generation() {
        let local: SocketAddr = "192.168.1.5:53317".parse().unwrap();
        let public: SocketAddr = "203.0.113.5:54321".parse().unwrap();

        let host = IceCandidate::host_candidate(local);
        assert_eq!(host.candidate_type, "host");
        assert_eq!(host.address, "192.168.1.5");
        assert_eq!(host.port, 53317);

        let srflx = IceCandidate::srflx_candidate(public, local);
        assert_eq!(srflx.candidate_type, "srflx");
        assert_eq!(srflx.address, "203.0.113.5");
        assert_eq!(srflx.port, 54321);
        assert_eq!(srflx.related_address, Some("192.168.1.5".to_string()));
    }

    #[test]
    fn test_nat_classification() {
        let local: SocketAddr = "10.0.0.2:12345".parse().unwrap();
        let same: SocketAddr = "10.0.0.2:12345".parse().unwrap();
        let same_port: SocketAddr = "203.0.113.1:12345".parse().unwrap();
        let diff_port: SocketAddr = "203.0.113.1:54321".parse().unwrap();

        assert_eq!(classify_nat(local, same), NatType::FullCone);
        assert_eq!(classify_nat(local, same_port), NatType::FullCone);
        assert_eq!(classify_nat(local, diff_port), NatType::PortRestrictedCone);
    }
}
