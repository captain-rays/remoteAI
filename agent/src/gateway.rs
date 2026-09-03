use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Json, State};
use axum::http::{Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use chrono::Utc;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::crypto::{CryptoError, CryptoReceiver};
use crate::event_buffer::EventBuffer;
use crate::pairing::{PairingError, PairingRegistry};
use crate::protocol::{EnvelopeKind, RequestEnvelope, validate_protocol_version};

#[derive(Clone)]
pub struct GatewayState {
    pub pairing: Arc<RwLock<PairingRegistry>>,
    pub event_buffer: Arc<Mutex<EventBuffer>>,
}

impl GatewayState {
    pub fn new(pairing: Arc<RwLock<PairingRegistry>>, event_capacity: usize) -> Self {
        Self {
            pairing,
            event_buffer: Arc::new(Mutex::new(EventBuffer::new(event_capacity))),
        }
    }
}

pub fn router(state: GatewayState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/pair", post(pair))
        .route(
            "/v1/ws",
            get(websocket).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .with_state(state)
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "name": crate::agent_name(),
        "status": "ok",
        "protocolVersion": crate::protocol::PROTOCOL_VERSION,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairRequest {
    pairing_secret: String,
    device_id: String,
    device_label: String,
    device_public_key: Vec<u8>,
}

async fn pair(State(state): State<GatewayState>, Json(request): Json<PairRequest>) -> Response {
    let result = state.pairing.write().await.pair(
        &request.pairing_secret,
        &request.device_id,
        &request.device_label,
        request.device_public_key,
        Utc::now(),
    );
    match result {
        Ok(()) => StatusCode::OK.into_response(),
        Err(PairingError::SecretAlreadyUsed) => StatusCode::CONFLICT.into_response(),
        Err(PairingError::SecretExpired) => StatusCode::GONE.into_response(),
        Err(_) => StatusCode::UNAUTHORIZED.into_response(),
    }
}

async fn ws_auth(
    State(state): State<GatewayState>,
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let Some(device_id) = request
        .headers()
        .get("x-remoteai-device")
        .and_then(|value| value.to_str().ok())
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    if state.pairing.read().await.authenticate(device_id).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    next.run(request).await
}

async fn websocket(upgrade: WebSocketUpgrade) -> Response {
    upgrade.on_upgrade(websocket_loop).into_response()
}

async fn websocket_loop(mut socket: WebSocket) {
    while let Some(Ok(message)) = socket.next().await {
        match message {
            Message::Ping(payload) => {
                if socket.send(Message::Pong(payload)).await.is_err() {
                    break;
                }
            }
            Message::Text(_) => {
                let _ = socket
                    .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code: 1008,
                        reason: "plaintext business frames are forbidden".into(),
                    })))
                    .await;
                break;
            }
            Message::Close(_) => break,
            Message::Binary(_) | Message::Pong(_) => {}
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutingMetadata {
    pub device_id: String,
    pub conversation_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EncryptedFrame {
    pub counter: u64,
    pub routing: RoutingMetadata,
    pub ciphertext: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum FrameError {
    #[error("plaintext business frames are forbidden")]
    PlaintextBusinessFrame,
    #[error("encrypted frame is malformed")]
    MalformedFrame,
    #[error("authentication or replay validation failed")]
    Authentication,
    #[error("request ID has already been processed")]
    DuplicateRequestId,
    #[error("request envelope is invalid")]
    InvalidEnvelope,
}

pub struct FrameProcessor {
    receiver: CryptoReceiver,
    seen_request_ids: HashSet<Uuid>,
}

impl FrameProcessor {
    pub fn new(receiver: CryptoReceiver) -> Self {
        Self {
            receiver,
            seen_request_ids: HashSet::new(),
        }
    }

    pub fn process(&mut self, bytes: &[u8]) -> Result<RequestEnvelope, FrameError> {
        let frame: EncryptedFrame =
            serde_json::from_slice(bytes).map_err(|_| FrameError::PlaintextBusinessFrame)?;
        let ciphertext = base64::engine::general_purpose::STANDARD
            .decode(frame.ciphertext)
            .map_err(|_| FrameError::MalformedFrame)?;
        let associated_data =
            serde_json::to_vec(&frame.routing).map_err(|_| FrameError::MalformedFrame)?;
        let plaintext = self
            .receiver
            .decrypt(frame.counter, &associated_data, &ciphertext)
            .map_err(map_crypto_error)?;
        let request: RequestEnvelope =
            serde_json::from_slice(&plaintext).map_err(|_| FrameError::InvalidEnvelope)?;
        validate_protocol_version(request.protocol_version)
            .map_err(|_| FrameError::InvalidEnvelope)?;
        if request.kind != EnvelopeKind::Request {
            return Err(FrameError::InvalidEnvelope);
        }
        if !self.seen_request_ids.insert(request.message_id) {
            return Err(FrameError::DuplicateRequestId);
        }
        Ok(request)
    }
}

fn map_crypto_error(_error: CryptoError) -> FrameError {
    FrameError::Authentication
}
