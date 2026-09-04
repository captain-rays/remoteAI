use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{DefaultBodyLimit, Json, Path as AxumPath, Query, State};
use axum::http::{HeaderMap, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use chrono::Utc;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::{RwLock, mpsc};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::adapters::ProviderAdapter;
use crate::audit::AuditLog;
use crate::catalog::build_catalog;
use crate::crypto::{
    CryptoBox, CryptoError, CryptoReceiver, derive_directional_keys, derive_shared_secret,
};
use crate::diagnostics::{Diagnostics, ProviderHealth};
use crate::event_buffer::EventBuffer;
use crate::files::FileService;
use crate::pairing::{PairingError, PairingRegistry};
use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, EnvelopeKind,
    ProviderId, RequestEnvelope, WriteState, validate_protocol_version,
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
    pub provider_adapters: Arc<RwLock<Vec<Arc<dyn ProviderAdapter>>>>,
    pub audit: AuditLog,
    pub diagnostics: Arc<Diagnostics>,
    mac_private_key: Arc<RwLock<Option<Zeroizing<[u8; 32]>>>>,
}

#[derive(Clone)]
pub struct GatewaySessionKeys {
    pub inbound: CryptoBox,
    pub outbound: CryptoBox,
}

#[derive(Debug, Error)]
pub enum SessionKeyError {
    #[error("mac private key is not configured")]
    MissingPrivateKey,
    #[error("device pairing is invalid: {0}")]
    Pairing(#[from] PairingError),
    #[error("session key derivation failed: {0}")]
    Crypto(#[from] CryptoError),
}

impl GatewayState {
    pub fn new(pairing: Arc<RwLock<PairingRegistry>>, event_capacity: usize) -> Self {
        Self {
            pairing,
            event_buffer: Arc::new(Mutex::new(EventBuffer::new(event_capacity))),
            sessions: Arc::new(RwLock::new(HashMap::new())),
            file_root: Arc::new(RwLock::new(None)),
            transfers: Arc::new(RwLock::new(None)),
            provider_adapters: Arc::new(RwLock::new(Vec::new())),
            audit: AuditLog::new(),
            diagnostics: Arc::new(Diagnostics::new(
                crate::agent_name(),
                Vec::<ProviderHealth>::new(),
            )),
            mac_private_key: Arc::new(RwLock::new(None)),
        }
    }

    pub async fn set_sessions(&self, provider: ProviderId, sessions: Vec<ConversationSummary>) {
        self.sessions.write().await.insert(provider, sessions);
    }

    pub async fn set_file_root(&self, root: impl AsRef<std::path::Path>) {
        *self.file_root.write().await = Some(FileService::new(root.as_ref()));
        *self.transfers.write().await = Some(TransferManager::new(root));
    }

    pub async fn set_mac_private_key(&self, private_key: [u8; 32]) {
        *self.mac_private_key.write().await = Some(Zeroizing::new(private_key));
    }

    pub async fn session_keys(
        &self,
        device_id: &str,
    ) -> Result<GatewaySessionKeys, SessionKeyError> {
        let private_key = self
            .mac_private_key
            .read()
            .await
            .clone()
            .ok_or(SessionKeyError::MissingPrivateKey)?;
        let pairing = self.pairing.read().await;
        let peer_public_key = pairing.device_public_key(device_id)?;
        let shared = derive_shared_secret(&private_key[..], &peer_public_key)?;
        let directional = derive_directional_keys(&shared, pairing.mac_id(), device_id)?;
        Ok(GatewaySessionKeys {
            inbound: CryptoBox::new(*directional.ios_to_mac, *b"IOS>"),
            outbound: CryptoBox::new(*directional.mac_to_ios, *b"MAC>"),
        })
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
    // This read is what the phone asked for, so index the provider now. A
    // failure keeps whatever was indexed before rather than emptying the list.
    state.refresh_provider(provider).await;
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
    // This read is what the phone asked for, so index the provider now. A
    // failure keeps whatever was indexed before rather than emptying the list.
    state.refresh_provider(provider).await;
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
    // This read is what the phone asked for, so index the provider now. A
    // failure keeps whatever was indexed before rather than emptying the list.
    state.refresh_provider(provider).await;
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
    #[serde(
        rename = "maxBytes",
        alias = "max_bytes",
        default = "default_preview_bytes"
    )]
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
        TransferError::Conflict {
            destination,
            existing_size,
        } => (
            StatusCode::CONFLICT,
            Json(serde_json::json!({
                "error": "conflict",
                "existingPath": destination,
                "existingSize": existing_size,
            })),
        )
            .into_response(),
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

async fn websocket(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let Some(device_id) = headers
        .get("x-remoteai-device")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let keys = match state.session_keys(&device_id).await {
        Ok(keys) => keys,
        Err(SessionKeyError::MissingPrivateKey) => {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
        Err(_) => return StatusCode::UNAUTHORIZED.into_response(),
    };
    let session =
        GatewaySession::new(state, device_id, keys.inbound.receiver(), keys.outbound).await;
    upgrade
        .on_upgrade(move |socket| websocket_loop(socket, session))
        .into_response()
}

async fn websocket_loop(mut socket: WebSocket, mut session: GatewaySession) {
    let mut events_open = true;
    loop {
        let keep_running = if events_open {
            tokio::select! {
                maybe_message = socket.next() => {
                    match maybe_message {
                        Some(Ok(message)) => process_socket_message(&mut socket, &mut session, message).await,
                        _ => false,
                    }
                }
                next_event = session.next_event() => {
                    match next_event {
                        Ok(Some(output)) => socket.send(Message::Binary(output.into())).await.is_ok(),
                        Ok(None) => {
                            events_open = false;
                            true
                        }
                        Err(_) => false,
                    }
                }
            }
        } else {
            match socket.next().await {
                Some(Ok(message)) => {
                    process_socket_message(&mut socket, &mut session, message).await
                }
                _ => false,
            }
        };
        if !keep_running {
            break;
        }
    }
}

async fn process_socket_message(
    socket: &mut WebSocket,
    session: &mut GatewaySession,
    message: Message,
) -> bool {
    match message {
        Message::Ping(payload) => socket.send(Message::Pong(payload)).await.is_ok(),
        Message::Text(_) => {
            let _ = socket
                .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                    code: 1008,
                    reason: "plaintext business frames are forbidden".into(),
                })))
                .await;
            false
        }
        Message::Binary(bytes) => match session.handle_frame(&bytes).await {
            Ok(outputs) => {
                for output in outputs {
                    if socket.send(Message::Binary(output.into())).await.is_err() {
                        return false;
                    }
                }
                true
            }
            Err(error) => {
                eprintln!(
                    "gateway websocket closing after frame rejection: {}",
                    gateway_error_code(&error)
                );
                let _ = socket
                    .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code: 1008,
                        reason: "encrypted business frame rejected".into(),
                    })))
                    .await;
                false
            }
        },
        Message::Close(_) => false,
        Message::Pong(_) => true,
    }
}

fn gateway_error_code(error: &GatewayBusinessError) -> &'static str {
    match error {
        GatewayBusinessError::Frame(_) => "frame_validation",
        GatewayBusinessError::WrongDevice => "wrong_device",
        GatewayBusinessError::InvalidPayload => "invalid_payload",
        GatewayBusinessError::UnsupportedRequest => "unsupported_request",
        GatewayBusinessError::ProviderUnavailable => "provider_unavailable",
        GatewayBusinessError::Provider(_) => "provider_operation",
        GatewayBusinessError::SessionBusy => "session_busy",
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

#[derive(Debug, Error)]
pub enum GatewayBusinessError {
    #[error("encrypted frame rejected: {0}")]
    Frame(#[from] FrameError),
    #[error("frame routing does not match authenticated device")]
    WrongDevice,
    #[error("request payload is invalid")]
    InvalidPayload,
    #[error("request type is unsupported")]
    UnsupportedRequest,
    #[error("provider is not registered")]
    ProviderUnavailable,
    #[error("provider operation failed: {0}")]
    Provider(String),
    #[error("session has another active writer")]
    SessionBusy,
}

/// Authenticated business dispatcher for one device WebSocket session.
/// It keeps adapter handles alive, decrypts requests, and encrypts all replies.
pub struct GatewaySession {
    state: GatewayState,
    device_id: String,
    processor: FrameProcessor,
    outbound: CryptoBox,
    outbound_counter: u64,
    event_rx: mpsc::Receiver<(ProviderId, ConversationEvent)>,
    active_conversations: HashMap<ProviderId, String>,
}

impl GatewaySession {
    pub async fn new(
        state: GatewayState,
        device_id: impl Into<String>,
        inbound: CryptoReceiver,
        outbound: CryptoBox,
    ) -> Self {
        let adapters = state.provider_adapters.read().await.clone();
        let (event_tx, event_rx) = mpsc::channel(64);
        for adapter in adapters {
            let provider = adapter.status().await.provider;
            let mut receiver = adapter.subscribe();
            let sender = event_tx.clone();
            tokio::spawn(async move {
                loop {
                    match receiver.recv().await {
                        Ok(event) => {
                            if sender.send((provider, event)).await.is_err() {
                                break;
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }
        drop(event_tx);
        Self {
            state,
            device_id: device_id.into(),
            processor: FrameProcessor::new(inbound),
            outbound,
            outbound_counter: 0,
            event_rx,
            active_conversations: HashMap::new(),
        }
    }

    pub async fn next_event(&mut self) -> Result<Option<Vec<u8>>, GatewayBusinessError> {
        let Some((provider, event)) = self.event_rx.recv().await else {
            return Ok(None);
        };
        let routing = RoutingMetadata {
            device_id: self.device_id.clone(),
            conversation_id: None,
        };
        self.encode_event(provider, event, &routing).map(Some)
    }

    pub async fn poll_event_frames(&mut self) -> Result<Vec<Vec<u8>>, GatewayBusinessError> {
        let routing = RoutingMetadata {
            device_id: self.device_id.clone(),
            conversation_id: None,
        };
        self.drain_pending_events(&routing).await
    }

    pub async fn handle_frame(
        &mut self,
        bytes: &[u8],
    ) -> Result<Vec<Vec<u8>>, GatewayBusinessError> {
        let frame: EncryptedFrame =
            serde_json::from_slice(bytes).map_err(|_| FrameError::PlaintextBusinessFrame)?;
        if frame.routing.device_id != self.device_id {
            return Err(GatewayBusinessError::WrongDevice);
        }
        let request = self.processor.process(bytes)?;
        let request_id = request
            .request_id
            .ok_or(GatewayBusinessError::InvalidPayload)?;
        let provider = request
            .payload
            .get("provider")
            .and_then(Value::as_str)
            .and_then(parse_provider)
            .ok_or(GatewayBusinessError::InvalidPayload)?;
        let operation: Result<(&str, Value), GatewayBusinessError> = async {
            let adapters = self.state.provider_adapters.read().await.clone();
            let mut adapter = None;
            for candidate in adapters {
                if candidate.status().await.provider == provider {
                    adapter = Some(candidate);
                    break;
                }
            }
            let adapter = adapter.ok_or(GatewayBusinessError::ProviderUnavailable)?;
            if matches!(
                request.message_type.as_str(),
                "conversation.resume" | "conversation.send"
            ) {
                let conversation_id = payload_string(&request.payload, "conversationId")?;
                match adapter
                    .write_availability(&conversation_id)
                    .await
                    .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?
                {
                    WriteState::Busy => return Err(GatewayBusinessError::SessionBusy),
                    WriteState::Unavailable => {
                        return Err(GatewayBusinessError::ProviderUnavailable);
                    }
                    WriteState::Available => {}
                }
            }
            Ok(match request.message_type.as_str() {
                "conversation.start" => {
                    let kind = parse_kind(&request.payload)?;
                    let cwd = request
                        .payload
                        .get("cwd")
                        .and_then(Value::as_str)
                        .map(PathBuf::from);
                    let id = adapter
                        .start(kind, cwd)
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "conversation.start.result",
                        serde_json::json!({"conversationId": id, "provider": provider}),
                    )
                }
                "conversation.resume" => {
                    let id = payload_string(&request.payload, "conversationId")?;
                    adapter
                        .resume(&id)
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "conversation.resume.result",
                        serde_json::json!({"conversationId": id, "provider": provider}),
                    )
                }
                "conversation.send" => {
                    let id = payload_string(&request.payload, "conversationId")?;
                    let text = payload_string(&request.payload, "text")?;
                    adapter
                        .send(&id, text, Vec::new())
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "conversation.send.result",
                        serde_json::json!({"conversationId": id, "provider": provider}),
                    )
                }
                "conversation.history" => {
                    let id = payload_string(&request.payload, "conversationId")?;
                    let cursor = request
                        .payload
                        .get("cursor")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let page = adapter
                        .load_conversation(&id, cursor)
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "conversation.history.result",
                        serde_json::json!({
                            "provider": provider,
                            "conversationId": page.conversation_id,
                            "events": page.events,
                            "nextCursor": page.next_cursor,
                        }),
                    )
                }
                "conversation.interrupt" => {
                    let id = payload_string(&request.payload, "conversationId")?;
                    adapter
                        .interrupt(&id)
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "conversation.interrupt.result",
                        serde_json::json!({"conversationId": id, "provider": provider}),
                    )
                }
                "approval.decide" => {
                    let id = payload_string(&request.payload, "requestId")?;
                    let decision = request
                        .payload
                        .get("decision")
                        .cloned()
                        .ok_or(GatewayBusinessError::InvalidPayload)
                        .and_then(|value| {
                            serde_json::from_value::<ApprovalDecision>(value)
                                .map_err(|_| GatewayBusinessError::InvalidPayload)
                        })?;
                    adapter
                        .decide_approval(&id, decision)
                        .await
                        .map_err(|error| GatewayBusinessError::Provider(error.to_string()))?;
                    (
                        "approval.decide.result",
                        serde_json::json!({"requestId": id, "provider": provider}),
                    )
                }
                "provider.status" => (
                    "provider.status.result",
                    serde_json::to_value(adapter.status().await)
                        .map_err(|_| GatewayBusinessError::InvalidPayload)?,
                ),
                _ => return Err(GatewayBusinessError::UnsupportedRequest),
            })
        }
        .await;

        let routing = RoutingMetadata {
            device_id: self.device_id.clone(),
            conversation_id: request
                .payload
                .get("conversationId")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        let (response_type, payload) = match operation {
            Ok(result) => result,
            Err(error) => {
                if matches!(error, GatewayBusinessError::UnsupportedRequest) {
                    return Err(error);
                }
                let error_kind = match error {
                    GatewayBusinessError::Provider(_) => "provider_operation_failed",
                    GatewayBusinessError::ProviderUnavailable => "provider_unavailable",
                    GatewayBusinessError::SessionBusy => "session_busy",
                    _ => "invalid_request",
                };
                return Ok(vec![self.encrypt_json(
                    &routing,
                    &serde_json::json!({
                        "protocolVersion": crate::protocol::PROTOCOL_VERSION,
                        "messageId": Uuid::new_v4(),
                        "kind": "response",
                        "requestId": request_id,
                        "type": "error",
                        "payload": {"code": error_kind},
                    }),
                )?]);
            }
        };
        if let Some(conversation_id) = payload
            .get("conversationId")
            .and_then(Value::as_str)
            .or_else(|| {
                request
                    .payload
                    .get("conversationId")
                    .and_then(Value::as_str)
            })
        {
            self.active_conversations
                .insert(provider, conversation_id.to_owned());
        }
        let mut outputs = vec![self.encrypt_json(
            &routing,
            &serde_json::json!({
                "protocolVersion": crate::protocol::PROTOCOL_VERSION,
                "messageId": Uuid::new_v4(),
                "kind": "response",
                "requestId": request_id,
                "type": response_type,
                "payload": payload,
            }),
        )?];
        outputs.extend(self.drain_pending_events(&routing).await?);
        Ok(outputs)
    }

    fn encrypt_json(
        &mut self,
        routing: &RoutingMetadata,
        value: &Value,
    ) -> Result<Vec<u8>, GatewayBusinessError> {
        self.outbound_counter = self.outbound_counter.saturating_add(1);
        let aad = serde_json::to_vec(routing).map_err(|_| GatewayBusinessError::InvalidPayload)?;
        let plaintext =
            serde_json::to_vec(value).map_err(|_| GatewayBusinessError::InvalidPayload)?;
        let ciphertext = self
            .outbound
            .encrypt(self.outbound_counter, &aad, &plaintext)
            .map_err(|_| GatewayBusinessError::InvalidPayload)?;
        serde_json::to_vec(&EncryptedFrame {
            counter: self.outbound_counter,
            routing: routing.clone(),
            ciphertext: base64::engine::general_purpose::STANDARD.encode(ciphertext),
        })
        .map_err(|_| GatewayBusinessError::InvalidPayload)
    }

    async fn drain_pending_events(
        &mut self,
        routing: &RoutingMetadata,
    ) -> Result<Vec<Vec<u8>>, GatewayBusinessError> {
        tokio::task::yield_now().await;
        let mut outputs = Vec::new();
        while let Ok((provider, event)) = self.event_rx.try_recv() {
            outputs.push(self.encode_event(provider, event, routing)?);
        }
        Ok(outputs)
    }

    fn encode_event(
        &mut self,
        provider: ProviderId,
        event: ConversationEvent,
        routing: &RoutingMetadata,
    ) -> Result<Vec<u8>, GatewayBusinessError> {
        let (message_type, payload) = event_parts(event);
        let conversation_id = payload
            .get("conversationId")
            .and_then(Value::as_str)
            .or(routing.conversation_id.as_deref())
            .or_else(|| self.active_conversations.get(&provider).map(String::as_str))
            .unwrap_or("unknown")
            .to_owned();
        let buffered = self
            .state
            .event_buffer
            .lock()
            .map_err(|_| GatewayBusinessError::InvalidPayload)?
            .push(
                &conversation_id,
                serde_json::json!({"type": message_type, "payload": payload}),
            );
        let event_routing = RoutingMetadata {
            device_id: routing.device_id.clone(),
            conversation_id: Some(conversation_id.clone()),
        };
        self.encrypt_json(
            &event_routing,
            &serde_json::json!({
                "protocolVersion": crate::protocol::PROTOCOL_VERSION,
                "messageId": Uuid::new_v4(),
                "kind": "event",
                "requestId": Value::Null,
                "sequence": buffered.sequence,
                "conversationId": conversation_id,
                "type": message_type,
                "payload": buffered.payload["payload"].clone(),
            }),
        )
    }
}

fn payload_string(payload: &Value, key: &str) -> Result<String, GatewayBusinessError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or(GatewayBusinessError::InvalidPayload)
}

fn parse_kind(payload: &Value) -> Result<ConversationKind, GatewayBusinessError> {
    payload
        .get("kind")
        .cloned()
        .ok_or(GatewayBusinessError::InvalidPayload)
        .and_then(|value| {
            serde_json::from_value(value).map_err(|_| GatewayBusinessError::InvalidPayload)
        })
}

fn event_parts(event: ConversationEvent) -> (String, Value) {
    match event {
        ConversationEvent::Delta { text } => (
            "conversation.delta".into(),
            serde_json::json!({"text": text}),
        ),
        ConversationEvent::Started(payload) => ("conversation.started".into(), payload),
        ConversationEvent::UserMessage(payload) => ("conversation.user_message".into(), payload),
        ConversationEvent::MessageCompleted(payload) => {
            ("conversation.message_completed".into(), payload)
        }
        ConversationEvent::ReasoningDelta(payload) => {
            ("conversation.reasoning_delta".into(), payload)
        }
        ConversationEvent::ReasoningCompleted(payload) => {
            ("conversation.reasoning_completed".into(), payload)
        }
        ConversationEvent::ToolStarted(payload) => ("tool.started".into(), payload),
        ConversationEvent::ToolUpdated(payload) => ("tool.updated".into(), payload),
        ConversationEvent::ToolCompleted(payload) => ("tool.completed".into(), payload),
        ConversationEvent::ApprovalRequested(payload) => ("approval.requested".into(), payload),
        ConversationEvent::ApprovalResolved(payload) => ("approval.resolved".into(), payload),
        ConversationEvent::TurnCompleted(payload) => ("turn.completed".into(), payload),
        ConversationEvent::TurnFailed(payload) => ("turn.failed".into(), payload),
        ConversationEvent::TurnInterrupted(payload) => ("turn.interrupted".into(), payload),
        ConversationEvent::ProviderStatusChanged(payload) => {
            ("provider.status_changed".into(), payload)
        }
        ConversationEvent::Unsupported { raw_type, payload } => (raw_type, payload),
    }
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
