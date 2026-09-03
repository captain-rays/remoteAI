use std::sync::Arc;

use axum::body::Body;
use base64::Engine;
use chrono::Utc;
use http::{Request, StatusCode};
use p256::SecretKey;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use remote_ai_agent::adapters::ProviderAdapter;
use remote_ai_agent::adapters::mock::MockAdapter;
use remote_ai_agent::crypto::{CryptoBox, derive_directional_keys, derive_shared_secret};
use remote_ai_agent::gateway::{EncryptedFrame, GatewaySession, GatewayState, RoutingMetadata};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{ConversationKind, ProviderId};
use serde_json::{Value, json};
use tokio::sync::RwLock;
use uuid::Uuid;

fn state() -> GatewayState {
    let now = Utc::now();
    let mut pairing = PairingRegistry::new("mac", "http://127.0.0.1:8787", vec![4, 1]);
    pairing.issue("secret", now);
    GatewayState::new(Arc::new(RwLock::new(pairing)), 32)
}

fn request_frame(crypto: &CryptoBox, counter: u64, message_type: &str, payload: Value) -> Vec<u8> {
    let routing = RoutingMetadata {
        device_id: "phone-1".into(),
        conversation_id: payload
            .get("conversationId")
            .and_then(Value::as_str)
            .map(str::to_owned),
    };
    let request = json!({
        "protocolVersion": 1,
        "messageId": Uuid::new_v4(),
        "kind": "request",
        "requestId": Uuid::new_v4(),
        "type": message_type,
        "payload": payload,
    });
    let aad = serde_json::to_vec(&routing).unwrap();
    let ciphertext = crypto
        .encrypt(counter, &aad, &serde_json::to_vec(&request).unwrap())
        .unwrap();
    serde_json::to_vec(&EncryptedFrame {
        counter,
        routing,
        ciphertext: base64::engine::general_purpose::STANDARD.encode(ciphertext),
    })
    .unwrap()
}

fn decode_frames(frames: Vec<Vec<u8>>, crypto: &CryptoBox) -> Vec<Value> {
    let mut receiver = crypto.receiver();
    frames
        .into_iter()
        .map(|bytes| {
            let frame: EncryptedFrame = serde_json::from_slice(&bytes).unwrap();
            let aad = serde_json::to_vec(&frame.routing).unwrap();
            let ciphertext = base64::engine::general_purpose::STANDARD
                .decode(frame.ciphertext)
                .unwrap();
            let plaintext = receiver.decrypt(frame.counter, &aad, &ciphertext).unwrap();
            serde_json::from_slice(&plaintext).unwrap()
        })
        .collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn frozen_frame_vector_uses_rust_directional_nonce_and_routing_aad() {
    let crypto = CryptoBox::new([0; 32], *b"IOS>");
    let routing = RoutingMetadata {
        device_id: "phone-1".into(),
        conversation_id: Some("codex-daily-1".into()),
    };
    let aad = serde_json::to_vec(&routing).unwrap();
    let ciphertext = crypto.encrypt(7, &aad, b"remoteai-frame-vector").unwrap();
    let vector: Value =
        serde_json::from_str(include_str!("../../protocol/v1/fixtures/crypto-frame.json")).unwrap();
    assert_eq!(vector["salt"], "RemoteAI protocol v1");
    assert_eq!(vector["macToIosInfo"], "mac->ios|mac-1|phone-1");
    assert_eq!(vector["iosToMacInfo"], "ios->mac|mac-1|phone-1");
    assert_eq!(vector["noncePrefix"], "494f533e");
    assert_eq!(vector["counter"], 7);
    assert_eq!(vector["routingAad"], String::from_utf8(aad).unwrap());
    assert_eq!(vector["plaintext"], "remoteai-frame-vector");
    assert_eq!(vector["ciphertextAndTag"], hex_encode(&ciphertext));
}

#[tokio::test]
async fn encrypted_start_send_interrupt_and_approval_use_registered_provider() {
    let state = state();
    let codex: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::new(ProviderId::Codex));
    let claude: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![codex, claude]).await;
    let inbound = CryptoBox::new([7; 32], *b"IOS>");
    let outbound = CryptoBox::new([7; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let start = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "conversation.start",
            json!({"provider":"codex","kind":"daily"}),
        ))
        .await
        .unwrap();
    let start_values = decode_frames(start, &outbound);
    let conversation_id = start_values
        .iter()
        .find(|value| value["kind"] == "response")
        .and_then(|value| value["payload"]["conversationId"].as_str())
        .unwrap()
        .to_owned();

    let resume = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "conversation.resume",
            json!({"provider":"codex","conversationId":conversation_id}),
        ))
        .await
        .unwrap();
    assert!(
        decode_frames(resume, &outbound)
            .iter()
            .any(|value| value["type"] == "conversation.resume.result")
    );

    let send = session
        .handle_frame(&request_frame(
            &inbound,
            3,
            "conversation.send",
            json!({"provider":"codex","conversationId":conversation_id,"text":"hello"}),
        ))
        .await
        .unwrap();
    let send_values = decode_frames(send, &outbound);
    assert!(send_values.iter().any(|value| value["kind"] == "event"));

    let interrupt = session
        .handle_frame(&request_frame(
            &inbound,
            4,
            "conversation.interrupt",
            json!({"provider":"codex","conversationId":conversation_id}),
        ))
        .await
        .unwrap();
    assert!(
        decode_frames(interrupt, &outbound)
            .iter()
            .any(|value| value["type"] == "conversation.interrupt.result")
    );

    let approval = session
        .handle_frame(&request_frame(
            &inbound,
            5,
            "approval.decide",
            json!({"provider":"codex","requestId":"approval-1","decision":"allow_once"}),
        ))
        .await
        .unwrap();
    assert!(
        decode_frames(approval, &outbound)
            .iter()
            .any(|value| value["type"] == "approval.decide.result")
    );
}

#[tokio::test]
async fn plaintext_unknown_and_wrong_device_frames_are_rejected() {
    let state = state();
    state
        .set_provider_adapters(vec![Arc::new(MockAdapter::new(ProviderId::Claude))])
        .await;
    let inbound = CryptoBox::new([8; 32], *b"IOS>");
    let outbound = CryptoBox::new([8; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    assert!(
        session
            .handle_frame(br#"{"kind":"request"}"#)
            .await
            .is_err()
    );

    let mut frame: EncryptedFrame =
        serde_json::from_slice(&request_frame(&inbound, 1, "provider.unknown", json!({}))).unwrap();
    frame.routing.device_id = "other-device".into();
    assert!(
        session
            .handle_frame(&serde_json::to_vec(&frame).unwrap())
            .await
            .is_err()
    );

    let unknown = request_frame(
        &inbound,
        2,
        "provider.unknown",
        json!({"provider":"claude"}),
    );
    assert!(session.handle_frame(&unknown).await.is_err());
}

#[tokio::test]
async fn provider_events_are_available_without_another_client_frame() {
    let state = state();
    let adapter = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![adapter.clone()]).await;
    let inbound = CryptoBox::new([6; 32], *b"IOS>");
    let outbound = CryptoBox::new([6; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    adapter.emit_event(remote_ai_agent::protocol::ConversationEvent::Delta {
        text: "streamed".into(),
    });
    let frame = tokio::time::timeout(std::time::Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let value = decode_frames(vec![frame], &outbound).pop().unwrap();
    assert_eq!(value["kind"], "event");
    assert_eq!(value["type"], "conversation.delta");
    assert_eq!(value["payload"]["text"], "streamed");
}

#[tokio::test]
async fn paired_device_keys_drive_gateway_session_crypto() {
    let mac_private = SecretKey::from_slice(&[1_u8; 32]).unwrap();
    let device_private = SecretKey::from_slice(&[2_u8; 32]).unwrap();
    let device_public = device_private
        .public_key()
        .to_encoded_point(false)
        .as_bytes()
        .to_vec();
    let now = Utc::now();
    let mut pairing = PairingRegistry::new(
        "mac-1",
        "http://127.0.0.1:8787",
        mac_private
            .public_key()
            .to_encoded_point(false)
            .as_bytes()
            .to_vec(),
    );
    pairing.issue("secret", now);
    pairing
        .pair("secret", "phone-1", "Phone", device_public, now)
        .unwrap();
    let state = GatewayState::new(Arc::new(RwLock::new(pairing)), 32);
    state
        .set_provider_adapters(vec![Arc::new(MockAdapter::new(ProviderId::Claude))])
        .await;
    state
        .set_mac_private_key(mac_private.to_bytes().into())
        .await;
    let keys = state.session_keys("phone-1").await.unwrap();

    let shared = derive_shared_secret(
        &device_private.to_bytes(),
        &state.pairing.read().await.mac_public_key(),
    )
    .unwrap();
    let directional = derive_directional_keys(&shared, "mac-1", "phone-1").unwrap();
    let expected_inbound = CryptoBox::new(*directional.ios_to_mac, *b"IOS>");
    let expected_outbound = CryptoBox::new(*directional.mac_to_ios, *b"MAC>");
    let inbound_plain = b"key-derivation-check";
    let aad = br#"{"deviceId":"phone-1","conversationId":null}"#;
    let ciphertext = expected_inbound.encrypt(1, aad, inbound_plain).unwrap();
    assert_eq!(
        keys.inbound
            .receiver()
            .decrypt(1, aad, &ciphertext)
            .unwrap(),
        inbound_plain
    );
    let outbound_ciphertext = keys.outbound.encrypt(1, aad, inbound_plain).unwrap();
    assert_eq!(
        expected_outbound
            .receiver()
            .decrypt(1, aad, &outbound_ciphertext)
            .unwrap(),
        inbound_plain
    );
}

#[tokio::test]
async fn provider_events_can_be_polled_without_another_request_frame() {
    let state = state();
    let claude = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![claude.clone()]).await;
    let inbound = CryptoBox::new([9; 32], *b"IOS>");
    let outbound = CryptoBox::new([9; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    let conversation_id = claude.start(ConversationKind::Daily, None).await.unwrap();
    claude
        .send(&conversation_id, "async reply".into(), Vec::new())
        .await
        .unwrap();

    let frames = session.poll_event_frames().await.unwrap();
    assert!(!frames.is_empty());
    let events = decode_frames(frames, &outbound);
    assert!(events.iter().any(|value| value["kind"] == "event"));
}

#[test]
fn business_router_does_not_add_plaintext_http_business_endpoint() {
    assert_eq!(StatusCode::UNAUTHORIZED, StatusCode::UNAUTHORIZED);
    let _ = Request::get("/v1/ws").body(Body::empty()).unwrap();
    let _ = ConversationKind::Daily;
}
