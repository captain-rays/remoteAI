use std::fs;
use std::sync::Arc;

use axum::body::Body;
use axum::body::to_bytes;
use base64::Engine;
use chrono::Utc;
use http::{Request, StatusCode};
use remote_ai_agent::audit::{AuditRecord, AuditRow};
use remote_ai_agent::crypto::CryptoBox;
use remote_ai_agent::event_buffer::EventBuffer;
use remote_ai_agent::gateway::{
    EncryptedFrame, FrameError, FrameProcessor, GatewayState, RoutingMetadata, router,
};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{ConversationKind, ConversationSummary, FileEntry, ProviderId};
use serde_json::json;
use tokio::sync::RwLock;
use tower::ServiceExt;
use uuid::Uuid;

fn paired_state() -> GatewayState {
    let now = Utc::now();
    let mut registry = PairingRegistry::new("mac-1", "https://agent.example", vec![4, 1]);
    registry.issue("secret", now);
    registry
        .pair("secret", "phone-1", "Phone", vec![4, 2], now)
        .unwrap();
    GatewayState::new(Arc::new(RwLock::new(registry)), 8)
}

#[tokio::test]
async fn health_is_public_but_websocket_requires_a_live_device() {
    let app = router(paired_state());
    let health = app
        .clone()
        .oneshot(Request::get("/v1/health").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);

    let websocket = app
        .oneshot(Request::get("/v1/ws").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(websocket.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn pair_endpoint_consumes_a_secret_once() {
    let now = Utc::now();
    let mut registry = PairingRegistry::new("mac-1", "https://agent.example", vec![4, 1]);
    registry.issue("single-use", now);
    let app = router(GatewayState::new(Arc::new(RwLock::new(registry)), 8));
    let body = json!({
        "pairingSecret": "single-use",
        "deviceId": "phone-1",
        "deviceLabel": "Phone",
        "devicePublicKey": [4, 2]
    });
    let request = || {
        Request::post("/v1/pair")
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    };
    assert_eq!(
        app.clone().oneshot(request()).await.unwrap().status(),
        StatusCode::OK
    );
    assert_eq!(
        app.oneshot(request()).await.unwrap().status(),
        StatusCode::CONFLICT
    );
}

#[tokio::test]
async fn authenticated_catalog_route_exposes_only_requested_provider_daily_sessions() {
    let state = paired_state();
    state
        .set_sessions(
            ProviderId::Codex,
            vec![ConversationSummary {
                id: "daily-codex".into(),
                provider: ProviderId::Codex,
                kind: ConversationKind::Daily,
                title: "Codex only".into(),
                project_id: None,
                project_path: None,
                updated_at: Utc::now(),
                status: "idle".into(),
                write_state: None,
                write_block_code: None,
            }],
        )
        .await;
    let response = router(state)
        .oneshot(
            Request::get("/v1/conversations/daily?provider=codex")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let values: Vec<ConversationSummary> = serde_json::from_slice(&body).unwrap();
    assert_eq!(values.len(), 1);
    assert_eq!(values[0].provider, ProviderId::Codex);
    assert_eq!(values[0].kind, ConversationKind::Daily);
}

#[tokio::test]
async fn project_conversations_route_filters_by_provider_and_project_id() {
    let state = paired_state();
    state
        .set_sessions(
            ProviderId::Codex,
            vec![ConversationSummary {
                id: "project-session".into(),
                provider: ProviderId::Codex,
                kind: ConversationKind::Project,
                title: "Project session".into(),
                project_id: Some("codex:project-1".into()),
                project_path: Some("/tmp/project".into()),
                updated_at: Utc::now(),
                status: "idle".into(),
                write_state: None,
                write_block_code: None,
            }],
        )
        .await;
    let response = router(state)
        .oneshot(
            Request::get("/v1/projects/codex:project-1/conversations?provider=codex")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let values: Vec<ConversationSummary> = serde_json::from_slice(&body).unwrap();
    assert_eq!(values.len(), 1);
    assert_eq!(values[0].kind, ConversationKind::Project);
}

#[tokio::test]
async fn authenticated_files_route_lists_only_explicitly_visible_entries() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("readme.txt"), "fixture").unwrap();
    fs::write(root.path().join(".hidden"), "secret").unwrap();
    let state = paired_state();
    state.set_file_root(root.path()).await;
    let response = router(state)
        .oneshot(
            Request::get("/v1/files/list?path=.&includeSensitive=false")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let entries: Vec<FileEntry> = serde_json::from_slice(&body).unwrap();
    assert!(entries.iter().any(|entry| entry.name == "readme.txt"));
    assert!(!entries.iter().any(|entry| entry.name == ".hidden"));
}

#[tokio::test]
async fn authenticated_audit_and_diagnostics_routes_are_redacted() {
    let state = paired_state();
    state.audit.record(AuditRecord {
        device_id: "phone-1".into(),
        provider: Some(ProviderId::Codex),
        conversation_id: None,
        action: "files.list".into(),
        target_path: Some("/tmp".into()),
        result: "ok token=secret".into(),
    });
    let app = router(state);
    let audit = app
        .clone()
        .oneshot(
            Request::get("/v1/audit")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(audit.status(), StatusCode::OK);
    let audit_body = to_bytes(audit.into_body(), usize::MAX).await.unwrap();
    let rows: Vec<AuditRow> = serde_json::from_slice(&audit_body).unwrap();
    assert_eq!(rows[0].result, "redacted");

    let diagnostics = app
        .oneshot(
            Request::get("/v1/diagnostics")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(diagnostics.status(), StatusCode::OK);
}

#[tokio::test]
async fn transfer_upload_requires_authentication_and_explicit_conflict_policy() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("same.txt"), "old").unwrap();
    let state = paired_state();
    state.set_file_root(root.path()).await;
    let app = router(state);
    let create = |headers: bool, body: &'static str| {
        let mut request = Request::post("/v1/transfers/create")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        if headers {
            request
                .headers_mut()
                .insert("x-remoteai-device", "phone-1".parse().unwrap());
        }
        request
    };
    assert_eq!(
        app.clone()
            .oneshot(create(false, r#"{"path":"new.txt"}"#))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.clone()
            .oneshot(create(true, r#"{"path":"same.txt"}"#))
            .await
            .unwrap()
            .status(),
        StatusCode::CONFLICT
    );
}

#[tokio::test]
async fn transfer_upload_decodes_base64_chunks_and_finishes_atomically() {
    let root = tempfile::tempdir().unwrap();
    let state = paired_state();
    state.set_file_root(root.path()).await;
    let app = router(state);
    let create = app
        .clone()
        .oneshot(
            Request::post("/v1/transfers/create")
                .header("x-remoteai-device", "phone-1")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"path":"payload.txt","sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create.status(), StatusCode::OK);
    let body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let transfer: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let transfer_id = transfer["id"].as_str().unwrap().to_owned();
    let path = format!("/v1/transfers/{transfer_id}/chunk");
    let chunk = app
        .clone()
        .oneshot(
            Request::post(path)
                .header("x-remoteai-device", "phone-1")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"offset":0,"data":"aGVsbG8="}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(chunk.status(), StatusCode::NO_CONTENT);
    let finish = app
        .oneshot(
            Request::post(format!("/v1/transfers/{transfer_id}/finish"))
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(finish.status(), StatusCode::NO_CONTENT);
    assert_eq!(fs::read(root.path().join("payload.txt")).unwrap(), b"hello");
}

#[tokio::test]
async fn transfer_download_requires_auth_and_honors_explicit_range() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("download.txt"), "0123456789").unwrap();
    let state = paired_state();
    state.set_file_root(root.path()).await;
    let app = router(state);
    let denied = app
        .clone()
        .oneshot(
            Request::get("/v1/transfers/download?path=download.txt&start=2&end=6")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let response = app
        .clone()
        .oneshot(
            Request::get("/v1/transfers/download?path=download.txt&start=2&end=6")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX).await.unwrap(),
        "2345"
    );
    let traversal = app
        .oneshot(
            Request::get("/v1/transfers/download?path=../download.txt&start=0&end=1")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(traversal.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn device_revoke_invalidates_future_authenticated_requests() {
    let app = router(paired_state());
    let response = app
        .clone()
        .oneshot(
            Request::post("/v1/device/revoke")
                .header("x-remoteai-device", "phone-1")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"deviceId":"phone-1"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let denied = app
        .oneshot(
            Request::get("/v1/audit")
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
}

#[test]
fn event_buffer_sequences_and_resumes_without_duplicates() {
    let mut buffer = EventBuffer::new(3);
    for value in 1..=4 {
        buffer.push("conversation-1", json!({"value": value}));
    }
    buffer.push("conversation-2", json!({"value": 1}));

    let resumed = buffer.after("conversation-1", 2);
    assert_eq!(
        resumed
            .iter()
            .map(|event| event.sequence)
            .collect::<Vec<_>>(),
        vec![3, 4]
    );
    assert_eq!(buffer.after("conversation-2", 0)[0].sequence, 1);
}

#[test]
fn encrypted_frame_processor_rejects_plaintext_replay_and_duplicate_ids() {
    let crypto = CryptoBox::new([9; 32], *b"IOS>");
    let routing = RoutingMetadata {
        device_id: "phone-1".into(),
        conversation_id: Some("conversation-1".into()),
    };
    let message_id = Uuid::new_v4();
    let request = json!({
        "protocolVersion": 1,
        "messageId": message_id,
        "kind": "request",
        "requestId": null,
        "type": "provider.status",
        "payload": {}
    });
    let aad = serde_json::to_vec(&routing).unwrap();
    let ciphertext = crypto
        .encrypt(1, &aad, &serde_json::to_vec(&request).unwrap())
        .unwrap();
    let frame = EncryptedFrame {
        counter: 1,
        routing: routing.clone(),
        ciphertext: base64::engine::general_purpose::STANDARD.encode(ciphertext),
    };

    let mut processor = FrameProcessor::new(crypto.receiver());
    assert_eq!(
        processor.process(br#"{"kind":"request"}"#),
        Err(FrameError::PlaintextBusinessFrame)
    );
    assert_eq!(
        processor
            .process(&serde_json::to_vec(&frame).unwrap())
            .unwrap()
            .message_id,
        message_id
    );

    let replay = EncryptedFrame {
        counter: 2,
        ciphertext: base64::engine::general_purpose::STANDARD.encode(
            crypto
                .encrypt(2, &aad, &serde_json::to_vec(&request).unwrap())
                .unwrap(),
        ),
        ..frame
    };
    assert_eq!(
        processor.process(&serde_json::to_vec(&replay).unwrap()),
        Err(FrameError::DuplicateRequestId)
    );
}
