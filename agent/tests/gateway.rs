use std::sync::Arc;

use axum::body::Body;
use base64::Engine;
use chrono::Utc;
use http::{Request, StatusCode};
use remote_ai_agent::crypto::CryptoBox;
use remote_ai_agent::event_buffer::EventBuffer;
use remote_ai_agent::gateway::{
    EncryptedFrame, FrameError, FrameProcessor, GatewayState, RoutingMetadata, router,
};
use remote_ai_agent::pairing::PairingRegistry;
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
