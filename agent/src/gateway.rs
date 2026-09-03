use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{DefaultBodyLimit, Json, Path as AxumPath, Query, State};
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

use crate::audit::AuditLog;
use crate::catalog::build_catalog;
use crate::crypto::{CryptoError, CryptoReceiver};
use crate::diagnostics::{Diagnostics, ProviderHealth};
use crate::event_buffer::EventBuffer;
use crate::files::FileService;
use crate::pairing::{PairingError, PairingRegistry};
use crate::protocol::{
    ConversationKind, ConversationSummary, EnvelopeKind, ProviderId, RequestEnvelope,
    validate_protocol_version,
};
use crate::transfers::{ConflictPolicy, TransferError, TransferManager};

const MAX_CHUNK_BYTES: usize = 4 * 1024 * 1024;
const MAX_CHUNK_BODY_BYTES: usize = 8 * 1024 * 1024;
const MAX_DOWNLOAD_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone)]
pub struct GatewayState {
    pub pairing: Arc<RwLock<PairingRegistry>>,
    pub event_buffer: Arc<Mutex<EventBuffer>>,
    pub sessions: Arc<RwLock<HashMap<ProviderId, Vec<ConversationSummary>>>>,
    pub file_root: Arc<RwLock<Option<FileService>>>,
    pub transfers: Arc<RwLock<Option<TransferManager>>>,
    pub audit: AuditLog,
    pub diagnostics: Arc<Diagnostics>,
}

impl GatewayState {
    pub fn new(pairing: Arc<RwLock<PairingRegistry>>, event_capacity: usize) -> Self {
        Self {
            pairing,
            event_buffer: Arc::new(Mutex::new(EventBuffer::new(event_capacity))),
            sessions: Arc::new(RwLock::new(HashMap::new())),
            file_root: Arc::new(RwLock::new(None)),
            transfers: Arc::new(RwLock::new(None)),
            audit: AuditLog::new(),
            diagnostics: Arc::new(Diagnostics::new(
                crate::agent_name(),
                Vec::<ProviderHealth>::new(),
            )),
        }
    }

    pub async fn set_sessions(&self, provider: ProviderId, sessions: Vec<ConversationSummary>) {
        self.sessions.write().await.insert(provider, sessions);
    }

    pub async fn set_file_root(&self, root: impl AsRef<std::path::Path>) {
        *self.file_root.write().await = Some(FileService::new(root.as_ref()));
        *self.transfers.write().await = Some(TransferManager::new(root));
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
        .route(
            "/v1/conversations/daily",
            get(daily_conversations)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/projects",
            get(projects).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/projects/{project_id}/conversations",
            get(project_conversations)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/files/list",
            get(files_list).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/files/metadata",
            get(files_metadata).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/files/preview",
            get(files_preview).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/transfers/create",
            post(transfer_create)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/transfers/{transfer_id}/chunk",
            post(transfer_chunk)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth))
                .layer(DefaultBodyLimit::max(MAX_CHUNK_BODY_BYTES)),
        )
        .route(
            "/v1/transfers/{transfer_id}/finish",
            post(transfer_finish)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/transfers/{transfer_id}/cancel",
            post(transfer_cancel)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/transfers/download",
            get(transfer_download)
                .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/audit",
            get(audit).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/diagnostics",
            get(diagnostics).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
        )
        .route(
            "/v1/device/revoke",
            post(revoke).route_layer(middleware::from_fn_with_state(state.clone(), ws_auth)),
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

#[derive(Debug, Deserialize)]
struct ProviderQuery {
    provider: String,
}

async fn daily_conversations(
    State(state): State<GatewayState>,
    Query(query): Query<ProviderQuery>,
) -> Response {
    let Some(provider) = parse_provider(&query.provider) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let sessions = state
        .sessions
        .read()
        .await
        .get(&provider)
        .cloned()
        .unwrap_or_default();
    match build_catalog(provider, ".", sessions) {
        Ok(catalog) => Json(
            catalog
                .conversations
                .into_iter()
                .filter(|item| item.kind == ConversationKind::Daily)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn projects(
    State(state): State<GatewayState>,
    Query(query): Query<ProviderQuery>,
) -> Response {
    let Some(provider) = parse_provider(&query.provider) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let sessions = state
        .sessions
        .read()
        .await
        .get(&provider)
        .cloned()
        .unwrap_or_default();
    match build_catalog(provider, ".", sessions) {
        Ok(catalog) => Json(catalog.projects).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn project_conversations(
    State(state): State<GatewayState>,
    AxumPath(project_id): AxumPath<String>,
    Query(query): Query<ProviderQuery>,
) -> Response {
    let Some(provider) = parse_provider(&query.provider) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let sessions = state
        .sessions
        .read()
        .await
        .get(&provider)
        .cloned()
        .unwrap_or_default();
    match build_catalog(provider, ".", sessions) {
        Ok(catalog) => Json(
            catalog
                .conversations
                .into_iter()
                .filter(|item| item.kind == ConversationKind::Project)
                .filter(|item| item.project_id.as_deref() == Some(project_id.as_str()))
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

fn parse_provider(raw: &str) -> Option<ProviderId> {
    match raw {
        "codex" => Some(ProviderId::Codex),
        "claude" => Some(ProviderId::Claude),
        _ => None,
    }
}

#[derive(Debug, Deserialize)]
struct FileListQuery {
    path: String,
    #[serde(rename = "includeSensitive", default)]
    include_sensitive: bool,
}

async fn files_list(
    State(state): State<GatewayState>,
    Query(query): Query<FileListQuery>,
) -> Response {
    let Some(service) = state.file_root.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match service.list(&PathBuf::from(query.path), query.include_sensitive) {
        Ok(entries) => Json(entries).into_response(),
        Err(crate::files::FilesError::PathOutsideRoot) => StatusCode::FORBIDDEN.into_response(),
        Err(crate::files::FilesError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

#[derive(Debug, Deserialize)]
struct FilePathQuery {
    path: String,
}

async fn files_metadata(
    State(state): State<GatewayState>,
    Query(query): Query<FilePathQuery>,
) -> Response {
    let Some(service) = state.file_root.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match service.metadata(&PathBuf::from(query.path)) {
        Ok(Some(entry)) => Json(entry).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(crate::files::FilesError::PathOutsideRoot) => StatusCode::FORBIDDEN.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

#[derive(Debug, Deserialize)]
struct PreviewQuery {
    path: String,
    #[serde(default = "default_preview_bytes")]
    max_bytes: usize,
}

async fn files_preview(
    State(state): State<GatewayState>,
    Query(query): Query<PreviewQuery>,
) -> Response {
    let Some(service) = state.file_root.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match service.preview(&PathBuf::from(query.path), query.max_bytes) {
        Ok(bytes) => axum::body::Body::from(bytes).into_response(),
        Err(crate::files::FilesError::PathOutsideRoot) => StatusCode::FORBIDDEN.into_response(),
        Err(crate::files::FilesError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransferCreateRequest {
    #[serde(alias = "destination", alias = "targetPath")]
    path: String,
    #[serde(default, alias = "sha256")]
    expected_sha256: Option<String>,
    #[serde(default, alias = "conflict")]
    conflict_policy: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransferChunkRequest {
    offset: u64,
    #[serde(alias = "base64")]
    data: String,
}

#[derive(Debug, Deserialize)]
struct TransferDownloadQuery {
    path: String,
    start: Option<u64>,
    end: Option<u64>,
}

async fn transfer_create(
    State(state): State<GatewayState>,
    Json(request): Json<TransferCreateRequest>,
) -> Response {
    let Some(manager) = state.transfers.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let policy = match request.conflict_policy.as_deref() {
        None => None,
        Some("keep_both") => Some(ConflictPolicy::KeepBoth),
        Some("overwrite") => Some(ConflictPolicy::Overwrite),
        Some(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    match manager
        .create_upload(
            &PathBuf::from(request.path),
            request.expected_sha256,
            policy,
        )
        .await
    {
        Ok(upload) => Json(serde_json::json!({
            "id": upload.id,
            "destination": upload.destination,
        }))
        .into_response(),
        Err(error) => transfer_error_response(error),
    }
}

async fn transfer_chunk(
    State(state): State<GatewayState>,
    AxumPath(transfer_id): AxumPath<String>,
    Json(request): Json<TransferChunkRequest>,
) -> Response {
    let Some(manager) = state.transfers.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let bytes = match base64::engine::general_purpose::STANDARD.decode(request.data) {
        Ok(bytes) if bytes.len() <= MAX_CHUNK_BYTES => bytes,
        Ok(_) => return StatusCode::PAYLOAD_TOO_LARGE.into_response(),
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    match manager
        .write_chunk(&transfer_id, request.offset, &bytes)
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => transfer_error_response(error),
    }
}

async fn transfer_finish(
    State(state): State<GatewayState>,
    AxumPath(transfer_id): AxumPath<String>,
) -> Response {
    let Some(manager) = state.transfers.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match manager.finish(&transfer_id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => transfer_error_response(error),
    }
}

async fn transfer_cancel(
    State(state): State<GatewayState>,
    AxumPath(transfer_id): AxumPath<String>,
) -> Response {
    let Some(manager) = state.transfers.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match manager.cancel(&transfer_id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => transfer_error_response(error),
    }
}

async fn transfer_download(
    State(state): State<GatewayState>,
    Query(query): Query<TransferDownloadQuery>,
) -> Response {
    let Some(manager) = state.transfers.read().await.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let start = query.start.unwrap_or(0);
    let end = query
        .end
        .unwrap_or(start.saturating_add(MAX_DOWNLOAD_BYTES));
    if end < start || end.saturating_sub(start) > MAX_DOWNLOAD_BYTES {
        return StatusCode::RANGE_NOT_SATISFIABLE.into_response();
    }
    match manager
        .read_range(&PathBuf::from(query.path), start, end)
        .await
    {
        Ok(bytes) => {
            let status = if query.start.is_some() || query.end.is_some() {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            };
            (
                status,
                [("content-type", "application/octet-stream")],
                bytes,
            )
                .into_response()
        }
        Err(error) => transfer_error_response(error),
    }
}

fn transfer_error_response(error: TransferError) -> Response {
    match error {
        TransferError::Conflict { .. } => StatusCode::CONFLICT.into_response(),
        TransferError::PathOutsideRoot => StatusCode::FORBIDDEN.into_response(),
        TransferError::UnknownTransfer => StatusCode::NOT_FOUND.into_response(),
        TransferError::InvalidOffset
        | TransferError::HashMismatch
        | TransferError::Authentication => StatusCode::BAD_REQUEST.into_response(),
        TransferError::Io(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

fn default_preview_bytes() -> usize {
    65_536
}

async fn audit(State(state): State<GatewayState>) -> Json<Vec<crate::audit::AuditRow>> {
    Json(state.audit.list())
}

async fn diagnostics(
    State(state): State<GatewayState>,
) -> Json<crate::diagnostics::DiagnosticsReport> {
    Json(
        state
            .diagnostics
            .report(crate::tunnel::TunnelManager::new())
            .await,
    )
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevokeRequest {
    device_id: String,
}

async fn revoke(State(state): State<GatewayState>, Json(request): Json<RevokeRequest>) -> Response {
    match state
        .pairing
        .write()
        .await
        .revoke(&request.device_id, Utc::now())
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(PairingError::DeviceUnknown) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
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
