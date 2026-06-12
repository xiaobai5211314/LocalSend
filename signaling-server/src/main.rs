use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, RwLock};
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

// ============================================================================
// Protocol Definitions
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SignalingMessage {
    // Client -> Server: register with device name
    #[serde(rename = "register")]
    Register {
        device_name: String,
    },

    // Server -> Client: registration confirmed
    #[serde(rename = "registered")]
    Registered {
        device_id: String,
    },

    // Client -> Server: request online device list
    #[serde(rename = "request_device_list")]
    RequestDeviceList,

    // Server -> Client: device list response
    #[serde(rename = "device_list")]
    DeviceList {
        devices: Vec<DeviceInfo>,
    },

    // Client -> Server -> Client: WebRTC SDP offer
    #[serde(rename = "offer")]
    Offer {
        from: String,
        to: String,
        payload: serde_json::Value,
    },

    // Client -> Server -> Client: WebRTC SDP answer
    #[serde(rename = "answer")]
    Answer {
        from: String,
        to: String,
        payload: serde_json::Value,
    },

    // Client -> Server -> Client: ICE candidate
    #[serde(rename = "ice_candidate")]
    IceCandidate {
        from: String,
        to: String,
        payload: serde_json::Value,
    },

    // Client -> Server -> Client: clipboard synchronization
    #[serde(rename = "clipboard_update")]
    ClipboardUpdate {
        from: String,
        to: String,
        payload: ClipboardPayload,
    },

    // Bidirectional: heartbeat
    #[serde(rename = "ping")]
    Ping,

    // Bidirectional: heartbeat reply
    #[serde(rename = "pong")]
    Pong,

    // Server -> All: device went offline
    #[serde(rename = "device_left")]
    DeviceLeft {
        device_id: String,
    },

    // Error response
    #[serde(rename = "error")]
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub device_id: String,
    pub device_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardPayload {
    pub content_type: String, // "text" | "url" | "image"
    pub content: String,
    pub timestamp: u64,
}

// ============================================================================
// Server State
// ============================================================================

struct DeviceConnection {
    device_name: String,
    sender: broadcast::Sender<String>,
}

struct AppState {
    devices: RwLock<HashMap<String, DeviceConnection>>,
}

impl AppState {
    fn new() -> Self {
        Self {
            devices: RwLock::new(HashMap::new()),
        }
    }

    async fn register_device(
        &self,
        device_name: String,
        sender: broadcast::Sender<String>,
    ) -> String {
        let device_id = Uuid::new_v4().to_string();
        let mut devices = self.devices.write().await;

        devices.insert(
            device_id.clone(),
            DeviceConnection {
                device_name,
                sender: sender.clone(),
            },
        );

        device_id
    }

    async fn unregister_device(&self, device_id: &str) {
        self.devices.write().await.remove(device_id);
    }

    async fn get_device_list(&self) -> Vec<DeviceInfo> {
        let devices = self.devices.read().await;
        devices
            .iter()
            .map(|(id, conn)| DeviceInfo {
                device_id: id.clone(),
                device_name: conn.device_name.clone(),
            })
            .collect()
    }

    async fn send_to_device(&self, target_id: &str, message: String) -> Result<(), String> {
        let devices = self.devices.read().await;
        match devices.get(target_id) {
            Some(conn) => {
                conn.sender
                    .send(message)
                    .map(|_| ())
                    .map_err(|e| format!("Failed to send to device {}: {}", target_id, e))
            }
            None => Err(format!("Device {} not found", target_id)),
        }
    }

    async fn broadcast(&self, message: String, exclude_id: Option<&str>) {
        let devices = self.devices.read().await;
        for (id, conn) in devices.iter() {
            if let Some(exclude) = exclude_id {
                if id == exclude {
                    continue;
                }
            }
            let _ = conn.sender.send(message.clone());
        }
    }
}

// ============================================================================
// Connection Handler
// ============================================================================

async fn handle_connection(
    state: Arc<AppState>,
    raw_stream: TcpStream,
    addr: SocketAddr,
) {
    log::info!("New connection from: {}", addr);

    let ws_stream = match tokio_tungstenite::accept_async(raw_stream).await {
        Ok(ws) => ws,
        Err(e) => {
            log::error!("WebSocket handshake failed: {}", e);
            return;
        }
    };

    let (mut ws_sender, mut ws_receiver) = ws_stream.split();

    // Broadcast channel for delivering messages to this connection's writer task
    let (tx, mut rx) = broadcast::channel::<String>(256);
    let mut device_id: Option<String> = None;

    // Spawn writer task
    let writer_tx = tx.clone();
    let mut writer_rx = tx.subscribe();
    let writer_handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                msg = writer_rx.recv() => {
                    match msg {
                        Ok(text) => {
                            if let Err(e) = ws_sender.send(Message::Text(text)).await {
                                log::error!("Write error: {}", e);
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            log::warn!("Writer lagged by {} messages", n);
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        }
    });

    // Ping heartbeat: every 30 seconds
    let ping_tx = writer_tx.clone();
    let ping_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(30));
        loop {
            interval.tick().await;
            let ping_msg = serde_json::to_string(&SignalingMessage::Ping).unwrap();
            if ping_tx.send(ping_msg).is_err() {
                break;
            }
        }
    });

    // Read loop
    while let Some(msg) = ws_receiver.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                if let Err(e) =
                    process_message(&state, &text, &mut device_id, &writer_tx, addr).await
                {
                    log::error!("Error processing message from {}: {}", addr, e);
                    let err_msg = serde_json::to_string(&SignalingMessage::Error {
                        message: e.to_string(),
                    })
                    .unwrap();
                    let _ = writer_tx.send(err_msg);
                }
            }
            Ok(Message::Close(_)) => {
                log::info!("Client {} closed connection", addr);
                break;
            }
            Ok(Message::Ping(data)) => {
                // Let tungstenite handle pong automatically via the stream
                let _ = writer_tx
                    .send(serde_json::to_string(&SignalingMessage::Pong).unwrap());
                log::trace!("Ping received from {} ({} bytes)", addr, data.len());
            }
            Ok(Message::Pong(_)) => {
                log::trace!("Pong received from {}", addr);
            }
            Err(e) => {
                log::error!("WebSocket error from {}: {}", addr);
                break;
            }
            _ => {}
        }
    }

    // Cleanup on disconnect
    ping_handle.abort();
    if let Some(ref id) = device_id {
        state.unregister_device(id).await;

        let leave_msg = serde_json::to_string(&SignalingMessage::DeviceLeft {
            device_id: id.clone(),
        })
        .unwrap();
        state.broadcast(leave_msg, Some(id)).await;
        log::info!("Device {} ({}) disconnected", id, addr);
    }

    writer_handle.abort();
}

async fn process_message(
    state: &Arc<AppState>,
    raw_text: &str,
    device_id: &mut Option<String>,
    sender: &broadcast::Sender<String>,
    addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error>> {
    let msg: SignalingMessage = serde_json::from_str(raw_text)?;

    match msg {
        SignalingMessage::Register { device_name } => {
            if device_id.is_some() {
                return Err("Already registered".into());
            }

            let new_id = state.register_device(device_name.clone(), sender.clone()).await;
            *device_id = Some(new_id.clone());

            // Send registration confirmation
            let response = SignalingMessage::Registered {
                device_id: new_id.clone(),
            };
            sender.send(serde_json::to_string(&response)?)?;

            // Notify others of new device
            let device_list = state.get_device_list().await;
            let list_msg = SignalingMessage::DeviceList {
                devices: device_list,
            };
            let list_json = serde_json::to_string(&list_msg)?;
            state.broadcast(list_json, Some(&new_id)).await;

            log::info!(
                "Device registered: {} ({}) from {}",
                device_name,
                new_id,
                addr
            );
        }

        SignalingMessage::RequestDeviceList => {
            if let Some(ref id) = device_id {
                let devices = state.get_device_list().await;
                let response = SignalingMessage::DeviceList { devices };
                sender.send(serde_json::to_string(&response)?)?;
                log::debug!("Device list sent to {}", id);
            } else {
                let error = SignalingMessage::Error {
                    message: "Not registered".to_string(),
                };
                sender.send(serde_json::to_string(&error)?)?;
            }
        }

        SignalingMessage::Offer { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::Offer {
                from: from.clone(),
                to: to.clone(),
                payload,
            };
            let relay_json = serde_json::to_string(&relay)?;
            if let Err(e) = state.send_to_device(&to, relay_json).await {
                let error = SignalingMessage::Error {
                    message: format!("Relay failed: {}", e),
                };
                sender.send(serde_json::to_string(&error)?)?;
            } else {
                log::info!("Offer relayed from {} to {}", from, to);
            }
        }

        SignalingMessage::Answer { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::Answer {
                from: from.clone(),
                to: to.clone(),
                payload,
            };
            let relay_json = serde_json::to_string(&relay)?;
            if let Err(e) = state.send_to_device(&to, relay_json).await {
                let error = SignalingMessage::Error {
                    message: format!("Relay failed: {}", e),
                };
                sender.send(serde_json::to_string(&error)?)?;
            } else {
                log::info!("Answer relayed from {} to {}", from, to);
            }
        }

        SignalingMessage::IceCandidate { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::IceCandidate {
                from: from.clone(),
                to: to.clone(),
                payload,
            };
            let relay_json = serde_json::to_string(&relay)?;
            if let Err(e) = state.send_to_device(&to, relay_json).await {
                let error = SignalingMessage::Error {
                    message: format!("Relay failed: {}", e),
                };
                sender.send(serde_json::to_string(&error)?)?;
            }
        }

        SignalingMessage::ClipboardUpdate { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::ClipboardUpdate {
                from: from.clone(),
                to: to.clone(),
                payload,
            };
            let relay_json = serde_json::to_string(&relay)?;
            if let Err(e) = state.send_to_device(&to, relay_json).await {
                let error = SignalingMessage::Error {
                    message: format!("Relay failed: {}", e),
                };
                sender.send(serde_json::to_string(&error)?)?;
            } else {
                log::info!("Clipboard update relayed from {} to {}", from, to);
            }
        }

        SignalingMessage::Ping => {
            let pong = SignalingMessage::Pong;
            sender.send(serde_json::to_string(&pong)?)?;
        }

        SignalingMessage::Pong => {
            // Heartbeat ACK received, no action needed
            log::trace!(
                "Pong from {}",
                device_id.as_deref().unwrap_or("unknown")
            );
        }

        _ => {
            // Messages that flow server->client only; ignore if received from client
            log::warn!("Unexpected message type from client: {:?}", msg);
        }
    }

    Ok(())
}

fn validate_sender(device_id: &Option<String>, expected: &str) -> Result<(), Box<dyn std::error::Error>> {
    match device_id {
        Some(id) if id == expected => Ok(()),
        Some(id) => Err(format!(
            "Sender mismatch: claimed {}, but registered as {}",
            expected, id
        )
        .into()),
        None => Err("Not registered".into()),
    }
}

// ============================================================================
// Main
// ============================================================================

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let state = Arc::new(AppState::new());
    let bind_addr = "0.0.0.0:9000";
    let listener = TcpListener::bind(bind_addr).await.expect("Failed to bind");

    log::info!("LocalSend Signaling Server listening on {}", bind_addr);
    log::info!("WebSocket endpoint: ws://0.0.0.0:9000");

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let state_clone = state.clone();
                tokio::spawn(async move {
                    handle_connection(state_clone, stream, addr).await;
                });
            }
            Err(e) => {
                log::error!("Accept error: {}", e);
            }
        }
    }
}
