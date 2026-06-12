use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use hyper::service::{make_service_fn, service_fn};
use hyper::{Body, Method, Request, Response, Server, StatusCode};
use serde::{Deserialize, Serialize};
use tokio::fs;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, RwLock};
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

// ============================================================================
// Protocol
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SignalingMessage {
    #[serde(rename = "register")]
    Register { device_name: String },

    #[serde(rename = "registered")]
    Registered { device_id: String },

    #[serde(rename = "request_device_list")]
    RequestDeviceList,

    #[serde(rename = "device_list")]
    DeviceList { devices: Vec<DeviceInfo> },

    #[serde(rename = "offer")]
    Offer { from: String, to: String, payload: serde_json::Value },

    #[serde(rename = "answer")]
    Answer { from: String, to: String, payload: serde_json::Value },

    #[serde(rename = "ice_candidate")]
    IceCandidate { from: String, to: String, payload: serde_json::Value },

    #[serde(rename = "clipboard_update")]
    ClipboardUpdate { from: String, to: String, payload: ClipboardPayload },

    #[serde(rename = "file_transfer")]
    FileTransfer {
        from: String,
        to: String,
        payload: FileTransferPayload,
    },

    #[serde(rename = "file_transfer_ack")]
    FileTransferAck {
        from: String,
        to: String,
        payload: FileTransferAckPayload,
    },

    #[serde(rename = "file_transfer_error")]
    FileTransferError {
        from: String,
        to: String,
        payload: FileTransferErrorPayload,
    },

    #[serde(rename = "ping")]
    Ping,

    #[serde(rename = "pong")]
    Pong,

    #[serde(rename = "device_left")]
    DeviceLeft { device_id: String },

    #[serde(rename = "error")]
    Error { message: String },

    /// Catch-all for unknown types (avoids deserialization failures)
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub device_id: String,
    pub device_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardPayload {
    pub content_type: String,
    pub content: String,
    pub timestamp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileTransferPayload {
    pub file_name: String,
    pub file_size: u64,
    pub transfer_id: String,
    pub download_url: String,
    pub sender_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileTransferAckPayload {
    pub transfer_id: String,
    pub file_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileTransferErrorPayload {
    pub transfer_id: String,
    pub file_name: String,
    pub error: String,
}

// ============================================================================
// State
// ============================================================================

struct DeviceConnection {
    device_name: String,
    sender: broadcast::Sender<String>,
}

struct AppState {
    devices: RwLock<HashMap<String, DeviceConnection>>,
    upload_dir: PathBuf,
}

impl AppState {
    fn new(upload_dir: PathBuf) -> Self {
        Self {
            devices: RwLock::new(HashMap::new()),
            upload_dir,
        }
    }

    async fn register_device(&self, device_name: String, sender: broadcast::Sender<String>) -> String {
        let device_id = Uuid::new_v4().to_string();
        self.devices.write().await.insert(
            device_id.clone(),
            DeviceConnection { device_name, sender: sender.clone() },
        );
        device_id
    }

    async fn unregister_device(&self, device_id: &str) {
        self.devices.write().await.remove(device_id);
    }

    async fn get_device_list(&self) -> Vec<DeviceInfo> {
        self.devices.read().await.iter().map(|(id, c)| DeviceInfo {
            device_id: id.clone(),
            device_name: c.device_name.clone(),
        }).collect()
    }

    async fn send_to_device(&self, target_id: &str, message: String) -> Result<(), String> {
        let devices = self.devices.read().await;
        match devices.get(target_id) {
            Some(c) => c.sender.send(message).map(|_| ()).map_err(|e| format!("Send failed: {}", e)),
            None => Err(format!("Device {} not found", target_id)),
        }
    }

    async fn broadcast(&self, message: String, exclude: Option<&str>) {
        for (id, c) in self.devices.read().await.iter() {
            if Some(id.as_str()) != exclude {
                let _ = c.sender.send(message.clone());
            }
        }
    }
}

// ============================================================================
// WebSocket Handler
// ============================================================================

async fn handle_connection(state: Arc<AppState>, raw: TcpStream, addr: SocketAddr) {
    log::info!("WS connection from {}", addr);
    let ws = match tokio_tungstenite::accept_async(raw).await {
        Ok(ws) => ws,
        Err(e) => { log::error!("WS handshake failed: {}", e); return; }
    };

    let (mut ws_tx, mut ws_rx) = ws.split();
    let (tx, mut rx) = broadcast::channel::<String>(256);
    let mut device_id: Option<String> = None;

    let writer_tx = tx.clone();
    let mut writer_rx = tx.subscribe();
    let writer_handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                msg = writer_rx.recv() => {
                    match msg {
                        Ok(text) => {
                            if ws_tx.send(Message::Text(text)).await.is_err() { break; }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            log::warn!("Writer lagged {}", n);
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        }
    });

    let ping_tx = writer_tx.clone();
    let ping_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(30));
        loop {
            interval.tick().await;
            if ping_tx.send(serde_json::to_string(&SignalingMessage::Ping).unwrap()).is_err() { break; }
        }
    });

    while let Some(msg) = ws_rx.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                if let Err(e) = process_message(&state, &text, &mut device_id, &writer_tx, addr).await {
                    log::error!("Error from {}: {}", addr, e);
                    let _ = writer_tx.send(serde_json::to_string(&SignalingMessage::Error { message: e.to_string() }).unwrap());
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) => {
                let _ = writer_tx.send(serde_json::to_string(&SignalingMessage::Pong).unwrap());
            }
            Err(e) => { log::error!("WS error {}: {}", addr, e); break; }
            _ => {}
        }
    }

    ping_handle.abort();
    if let Some(ref id) = device_id {
        state.unregister_device(id).await;
        let leave = serde_json::to_string(&SignalingMessage::DeviceLeft { device_id: id.clone() }).unwrap();
        state.broadcast(leave, Some(id)).await;
        log::info!("Device {} disconnected", id);
    }
    writer_handle.abort();
}

async fn process_message(
    state: &Arc<AppState>,
    raw: &str,
    device_id: &mut Option<String>,
    sender: &broadcast::Sender<String>,
    addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error>> {
    let msg: SignalingMessage = serde_json::from_str(raw)?;

    match msg {
        SignalingMessage::Register { device_name } => {
            if device_id.is_some() {
                return Err("Already registered".into());
            }
            let new_id = state.register_device(device_name.clone(), sender.clone()).await;
            *device_id = Some(new_id.clone());

            sender.send(serde_json::to_string(&SignalingMessage::Registered { device_id: new_id.clone() })?)?;

            let list = state.get_device_list().await;
            let list_json = serde_json::to_string(&SignalingMessage::DeviceList { devices: list })?;
            state.broadcast(list_json, Some(&new_id)).await;

            log::info!("REG {}={} from {}", device_name, new_id, addr);
        }

        SignalingMessage::RequestDeviceList => {
            if let Some(ref id) = device_id {
                let list = state.get_device_list().await;
                sender.send(serde_json::to_string(&SignalingMessage::DeviceList { devices: list })?)?;
                log::debug!("Device list sent to {}", id);
            }
        }

        SignalingMessage::Offer { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::Offer { from: from.clone(), to: to.clone(), payload };
            let json = serde_json::to_string(&relay)?;
            match state.send_to_device(&to, json).await {
                Ok(()) => log::info!("FWD offer {} -> {}", from, to),
                Err(e) => {
                    log::warn!("FWD offer {} -> {} FAILED: {}", from, to, e);
                    let _ = sender.send(serde_json::to_string(&SignalingMessage::Error { message: e })?);
                }
            }
        }

        SignalingMessage::Answer { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::Answer { from: from.clone(), to: to.clone(), payload };
            let json = serde_json::to_string(&relay)?;
            match state.send_to_device(&to, json).await {
                Ok(()) => log::info!("FWD answer {} -> {}", from, to),
                Err(e) => {
                    log::warn!("FWD answer {} -> {} FAILED: {}", from, to, e);
                    let _ = sender.send(serde_json::to_string(&SignalingMessage::Error { message: e })?);
                }
            }
        }

        SignalingMessage::IceCandidate { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::IceCandidate { from: from.clone(), to: to.clone(), payload };
            let json = serde_json::to_string(&relay)?;
            let _ = state.send_to_device(&to, json).await;
        }

        SignalingMessage::ClipboardUpdate { from, to, payload } => {
            validate_sender(device_id, &from)?;
            let relay = SignalingMessage::ClipboardUpdate { from: from.clone(), to: to.clone(), payload };
            let json = serde_json::to_string(&relay)?;
            let _ = state.send_to_device(&to, json).await;
        }

        SignalingMessage::FileTransfer { from, to, ref payload } => {
            validate_sender(device_id, &from)?;
            log::info!(
                "FILE_TRANSFER from={} to={} file={} size={} url={}",
                from, to, payload.file_name, payload.file_size, payload.download_url
            );
            let relay = SignalingMessage::FileTransfer {
                from: from.clone(),
                to: to.clone(),
                payload: payload.clone(),
            };
            let json = serde_json::to_string(&relay)?;
            match state.send_to_device(&to, json).await {
                Ok(()) => log::info!("FILE_TRANSFER forwarded OK"),
                Err(e) => {
                    log::warn!("FILE_TRANSFER target {} not found: {}", to, e);
                    let err = SignalingMessage::FileTransferError {
                        from: to.clone(),
                        to: from.clone(),
                        payload: FileTransferErrorPayload {
                            transfer_id: payload.transfer_id.clone(),
                            file_name: payload.file_name.clone(),
                            error: format!("Target device {} not found", to),
                        },
                    };
                    let _ = sender.send(serde_json::to_string(&err)?);
                }
            }
        }

        SignalingMessage::FileTransferAck { from, to, ref payload } => {
            validate_sender(device_id, &from)?;
            log::info!(
                "FILE_ACK from={} to={} file={} tid={}",
                from, to, payload.file_name, payload.transfer_id
            );
            let relay = SignalingMessage::FileTransferAck {
                from: from.clone(),
                to: to.clone(),
                payload: payload.clone(),
            };
            let json = serde_json::to_string(&relay)?;
            let _ = state.send_to_device(&to, json).await;
        }

        SignalingMessage::FileTransferError { from, to, ref payload } => {
            validate_sender(device_id, &from)?;
            log::info!(
                "FILE_ERROR from={} to={} file={} err={}",
                from, to, payload.file_name, payload.error
            );
            let relay = SignalingMessage::FileTransferError {
                from: from.clone(),
                to: to.clone(),
                payload: payload.clone(),
            };
            let json = serde_json::to_string(&relay)?;
            let _ = state.send_to_device(&to, json).await;
        }

        SignalingMessage::Ping => {
            sender.send(serde_json::to_string(&SignalingMessage::Pong)?)?;
        }

        SignalingMessage::Pong => {}

        SignalingMessage::Unknown => {
            log::warn!("Unknown message type from {}: {}", addr, raw.chars().take(200).collect::<String>());
        }

        _ => {
            log::warn!("Unexpected msg from {}: {:?}", addr, raw.chars().take(100).collect::<String>());
        }
    }

    Ok(())
}

fn validate_sender(device_id: &Option<String>, expected: &str) -> Result<(), Box<dyn std::error::Error>> {
    match device_id {
        Some(id) if id == expected => Ok(()),
        Some(id) => Err(format!("Sender mismatch: claimed {}, registered as {}", expected, id).into()),
        None => Err("Not registered".into()),
    }
}

// ============================================================================
// HTTP Relay Server (upload / download / health)
// ============================================================================

async fn handle_http(
    state: Arc<AppState>,
    req: Request<Body>,
) -> Result<Response<Body>, hyper::Error> {
    let method = req.method().clone();
    let path = req.uri().path().to_string();

    match (method, path.as_str()) {
        (Method::GET, "/health") => {
            let body = serde_json::json!({
                "status": "ok",
                "service": "localsend-signaling",
                "version": "0.2.0"
            });
            Ok(Response::builder()
                .header("Content-Type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap())
        }

        (Method::POST, "/api/upload") => {
            log::info!("HTTP POST /api/upload received");
            let whole_body = hyper::body::to_bytes(req.into_body()).await?;
            let file_id = Uuid::new_v4().to_string();
            let file_path = state.upload_dir.join(&file_id);

            fs::write(&file_path, &whole_body).await.map_err(|e| {
                log::error!("Failed to write file: {}", e);
                e
            })?;

            let size = whole_body.len();
            log::info!("UPLOADED file_id={} size={}", file_id, size);

            let body = serde_json::json!({
                "file_id": file_id,
                "size": size
            });
            Ok(Response::builder()
                .header("Content-Type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap())
        }

        (Method::GET, path) if path.starts_with("/api/files/") => {
            let file_id = path.trim_start_matches("/api/files/");
            let file_path = state.upload_dir.join(file_id);

            if !file_path.exists() {
                log::warn!("DOWNLOAD not found: {}", file_id);
                return Ok(Response::builder()
                    .status(StatusCode::NOT_FOUND)
                    .body(Body::from("File not found"))
                    .unwrap());
            }

            let data = fs::read(&file_path).await.map_err(|e| {
                log::error!("Failed to read file {}: {}", file_id, e);
                e
            })?;

            let size = data.len();
            log::info!("DOWNLOADED file_id={} size={}", file_id, size);

            // Cleanup after download
            let _ = fs::remove_file(&file_path).await;

            Ok(Response::builder()
                .header("Content-Type", "application/octet-stream")
                .header("Content-Length", size)
                .body(Body::from(data))
                .unwrap())
        }

        _ => {
            Ok(Response::builder()
                .status(StatusCode::NOT_FOUND)
                .body(Body::from("Not found"))
                .unwrap())
        }
    }
}

// ============================================================================
// Main
// ============================================================================

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let upload_dir = PathBuf::from("/var/lib/localsend/uploads");
    fs::create_dir_all(&upload_dir).await.ok();

    let state = Arc::new(AppState::new(upload_dir.clone()));

    // --- WebSocket server on port 9000 ---
    let ws_state = state.clone();
    let ws_handle = tokio::spawn(async move {
        let listener = TcpListener::bind("0.0.0.0:9000").await.expect("Failed to bind WS");
        log::info!("WebSocket server on 0.0.0.0:9000");
        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    let s = ws_state.clone();
                    tokio::spawn(async move { handle_connection(s, stream, addr).await; });
                }
                Err(e) => log::error!("Accept error: {}", e),
            }
        }
    });

    // --- HTTP relay server on port 9001 ---
    let http_state = state.clone();
    let http_handle = tokio::spawn(async move {
        let addr = SocketAddr::from(([0, 0, 0, 0], 9001));
        let make_svc = make_service_fn(move |_conn| {
            let s = http_state.clone();
            async move {
                Ok::<_, hyper::Error>(service_fn(move |req| {
                    handle_http(s.clone(), req)
                }))
            }
        });
        let server = Server::bind(&addr).serve(make_svc);
        log::info!("HTTP relay server on 0.0.0.0:9001");
        if let Err(e) = server.await {
            log::error!("HTTP server error: {}", e);
        }
    });

    log::info!("LocalSend Signaling Server v0.2.0 started");
    log::info!("  WebSocket: ws://0.0.0.0:9000");
    log::info!("  HTTP relay: http://0.0.0.0:9001");
    log::info!("  Upload dir: {:?}", upload_dir);

    let _ = tokio::join!(ws_handle, http_handle);
}
