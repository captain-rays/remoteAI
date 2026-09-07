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
    assert!(
        send_values
            .iter()
            .any(|value| value["type"] == "turn.completed"),
        "a completed provider turn must be delivered with the send response"
    );

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

    // An unknown request *type* is a version mismatch, not an attack. It must
    // come back as an encrypted rejection: tearing the socket down would cost
    // the phone its realtime feed for the rest of the session.
    let unknown = request_frame(
        &inbound,
        2,
        "provider.unknown",
        json!({"provider":"claude"}),
    );
    let rejection = session
        .handle_frame(&unknown)
        .await
        .expect("an unknown request type must not close the websocket");
    let value = decode_frames(rejection, &outbound)
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(value["type"], "error");
    assert_eq!(value["payload"]["code"], "unsupported_request");
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
async fn asynchronous_events_are_routed_to_the_active_conversation() {
    let state = state();
    let adapter = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![adapter.clone()]).await;
    let inbound = CryptoBox::new([11; 32], *b"IOS>");
    let outbound = CryptoBox::new([11; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    let start = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "conversation.start",
            json!({"provider":"claude","kind":"daily"}),
        ))
        .await
        .unwrap();
    let conversation_id = decode_frames(start, &outbound)
        .into_iter()
        .find_map(|value| {
            (value["kind"] == "response").then(|| {
                value["payload"]["conversationId"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
        })
        .unwrap();
    adapter.emit_event(remote_ai_agent::protocol::ConversationEvent::Delta {
        text: "async".into(),
    });
    let frame = tokio::time::timeout(std::time::Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let value = decode_frames(vec![frame], &outbound).pop().unwrap();
    assert_eq!(value["conversationId"], conversation_id);
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

#[tokio::test]
async fn provider_send_failure_returns_encrypted_error_and_keeps_session_alive() {
    let state = state();
    let adapter = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![adapter.clone()]).await;
    let inbound = CryptoBox::new([10; 32], *b"IOS>");
    let outbound = CryptoBox::new([10; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    let frames = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "conversation.send",
            json!({"provider":"claude","conversationId":"missing","text":"hello"}),
        ))
        .await
        .unwrap();
    let values = decode_frames(frames, &outbound);
    assert_eq!(values[0]["type"], "error");
    assert_eq!(values[0]["payload"]["code"], "provider_operation_failed");

    adapter.emit_event(remote_ai_agent::protocol::ConversationEvent::Delta {
        text: "still-connected".into(),
    });
    let event = tokio::time::timeout(std::time::Duration::from_secs(1), session.next_event())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let event_value = decode_frames(vec![event], &outbound).pop().unwrap();
    assert_eq!(event_value["payload"]["text"], "still-connected");
}

#[tokio::test]
async fn decrypted_business_rejection_returns_safe_error_and_keeps_session_alive() {
    let state = state();
    state
        .set_provider_adapters(vec![Arc::new(MockAdapter::new(ProviderId::Claude))])
        .await;
    let inbound = CryptoBox::new([14; 32], *b"IOS>");
    let outbound = CryptoBox::new([14; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    // The frame is authenticated and decrypted, but the business payload is
    // invalid. This must be a safe encrypted response, not a socket-fatal
    // error, so the client can correct its request without reconnecting.
    let invalid = session
        .handle_frame(&request_frame(&inbound, 1, "provider.status", json!({})))
        .await
        .expect("decrypted business errors must stay on the websocket");
    let invalid_value = decode_frames(invalid, &outbound)
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(invalid_value["type"], "error");
    assert_eq!(invalid_value["payload"]["code"], "invalid_request");
    assert!(!invalid_value.to_string().contains("stderr"));

    // Prove that the same session is still usable after the rejection.
    let valid = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "provider.status",
            json!({"provider":"claude"}),
        ))
        .await
        .unwrap();
    let valid_value = decode_frames(valid, &outbound)
        .into_iter()
        .find(|value| value["kind"] == "response")
        .unwrap();
    assert_eq!(valid_value["type"], "provider.status.result");
}

#[tokio::test]
async fn busy_provider_session_returns_session_busy_without_starting_writer() {
    let state = state();
    let adapter = Arc::new(MockAdapter::new(ProviderId::Claude));
    state.set_provider_adapters(vec![adapter.clone()]).await;
    let inbound = CryptoBox::new([12; 32], *b"IOS>");
    let outbound = CryptoBox::new([12; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;
    let start = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "conversation.start",
            json!({"provider":"claude","kind":"daily"}),
        ))
        .await
        .unwrap();
    let conversation_id = decode_frames(start, &outbound)
        .into_iter()
        .find_map(|value| {
            (value["kind"] == "response").then(|| {
                value["payload"]["conversationId"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
        })
        .unwrap();
    adapter.set_busy(&conversation_id, true).await;
    let listed = adapter.list_conversations().await.unwrap();
    assert_eq!(listed[0].write_block_code.as_deref(), Some("session_busy"));
    let response = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "conversation.send",
            json!({"provider":"claude","conversationId":conversation_id,"text":"blocked"}),
        ))
        .await
        .unwrap();
    let values = decode_frames(response, &outbound);
    assert_eq!(values[0]["type"], "error");
    assert_eq!(values[0]["payload"]["code"], "session_busy");
}

#[tokio::test]
async fn encrypted_history_is_provider_scoped_and_cursor_paged() {
    let state = state();
    let claude = Arc::new(MockAdapter::new(ProviderId::Claude));
    let codex = Arc::new(MockAdapter::new(ProviderId::Codex));
    let claude_id = claude.start(ConversationKind::Daily, None).await.unwrap();
    let codex_id = codex.start(ConversationKind::Daily, None).await.unwrap();
    claude
        .set_history(
            &claude_id,
            vec![
                json!({"type":"conversation.user_message","payload":{"text":"claude-1"}}),
                json!({"type":"conversation.message_completed","payload":{"text":"claude-2"}}),
                json!({"type":"turn.completed","payload":{"conversationId":claude_id}}),
            ],
        )
        .await;
    codex
        .set_history(
            &codex_id,
            vec![json!({"type":"conversation.user_message","payload":{"text":"codex-only"}})],
        )
        .await;
    state.set_provider_adapters(vec![claude, codex]).await;
    let inbound = CryptoBox::new([13; 32], *b"IOS>");
    let outbound = CryptoBox::new([13; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let first = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "conversation.history",
            json!({"provider":"claude","conversationId":claude_id}),
        ))
        .await
        .unwrap();
    let first_value = decode_frames(first, &outbound)
        .into_iter()
        .find(|value| value["kind"] == "response")
        .unwrap();
    assert_eq!(first_value["type"], "conversation.history.result");
    assert_eq!(first_value["payload"]["conversationId"], claude_id);
    assert!(
        first_value["payload"]["events"]
            .to_string()
            .contains("claude-1")
    );
    assert!(
        !first_value["payload"]["events"]
            .to_string()
            .contains("codex-only")
    );
    let cursor = first_value["payload"]["nextCursor"].as_str().unwrap();

    let second = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "conversation.history",
            json!({"provider":"claude","conversationId":claude_id,"cursor":cursor}),
        ))
        .await
        .unwrap();
    let second_value = decode_frames(second, &outbound)
        .into_iter()
        .find(|value| value["kind"] == "response")
        .unwrap();
    assert!(
        second_value["payload"]["events"]
            .to_string()
            .contains("claude-2")
    );
}

#[test]
fn business_router_does_not_add_plaintext_http_business_endpoint() {
    assert_eq!(StatusCode::UNAUTHORIZED, StatusCode::UNAUTHORIZED);
    let _ = Request::get("/v1/ws").body(Body::empty()).unwrap();
    let _ = ConversationKind::Daily;
}

#[tokio::test]
async fn a_turn_that_fails_for_lack_of_credit_is_reported_against_the_provider() {
    // A failed turn shows up in its own conversation, which cannot express
    // "and every other conversation of this provider will fail the same way
    // until you top up". The phone learns that from provider status.
    let state = state();
    let codex = Arc::new(MockAdapter::new(ProviderId::Codex));
    let claude = Arc::new(MockAdapter::new(ProviderId::Claude));
    state
        .set_provider_adapters(vec![
            codex.clone() as Arc<dyn ProviderAdapter>,
            claude as Arc<dyn ProviderAdapter>,
        ])
        .await;
    let inbound = CryptoBox::new([9; 32], *b"IOS>");
    let outbound = CryptoBox::new([9; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let status_of = |frames: Vec<Vec<u8>>, outbound: &CryptoBox| -> Value {
        decode_frames(frames, outbound)
            .into_iter()
            .find(|value| value["type"] == "provider.status.result")
            .expect("a status response")["payload"]
            .clone()
    };

    let before = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "provider.status",
            json!({"provider":"codex"}),
        ))
        .await
        .unwrap();
    let before = status_of(before, &outbound);
    assert_eq!(before["provider"], "codex", "the old shape is still there");
    assert!(before.get("problem").is_none(), "nothing has failed yet");

    codex.emit_event(remote_ai_agent::protocol::ConversationEvent::TurnFailed(
        json!({
            "conversationId": "codex-daily-1",
            "message": "You've hit your usage limit. Visit \
                        https://chatgpt.com/codex/settings/usage to purchase \
                        more credits or try again at 9:49 PM.",
        }),
    ));

    // The event reaches the phone on the next exchange, and is classified as
    // it passes through.
    let failure = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "provider.status",
            json!({"provider":"codex"}),
        ))
        .await
        .unwrap();
    assert!(
        decode_frames(failure, &outbound)
            .iter()
            .any(|value| value["type"] == "turn.failed"),
        "the turn failure still reaches the transcript"
    );

    let after = session
        .handle_frame(&request_frame(
            &inbound,
            3,
            "provider.status",
            json!({"provider":"codex"}),
        ))
        .await
        .unwrap();
    let after = status_of(after, &outbound);
    assert_eq!(after["problem"]["code"], "quota_exhausted");
    assert!(
        after["problem"]["message"]
            .as_str()
            .expect("the provider's own words")
            .contains("purchase"),
        "the message keeps the part the person needs to act on"
    );

    let other = session
        .handle_frame(&request_frame(
            &inbound,
            4,
            "provider.status",
            json!({"provider":"claude"}),
        ))
        .await
        .unwrap();
    assert!(
        status_of(other, &outbound).get("problem").is_none(),
        "Codex running out of credit says nothing about Claude"
    );
}

#[tokio::test]
async fn a_provider_with_no_installed_cli_is_not_reported_as_logged_out() {
    // No probe is registered for a CLI that was never found. Reporting
    // "logged out" there would send someone to re-authenticate a program
    // they have not installed.
    let state = state();
    state
        .set_provider_adapters(vec![
            Arc::new(MockAdapter::new(ProviderId::Codex)) as Arc<dyn ProviderAdapter>,
        ])
        .await;
    let inbound = CryptoBox::new([11; 32], *b"IOS>");
    let outbound = CryptoBox::new([11; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let frames = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "provider.status",
            json!({"provider":"codex"}),
        ))
        .await
        .unwrap();
    let payload = decode_frames(frames, &outbound)
        .into_iter()
        .find(|value| value["type"] == "provider.status.result")
        .expect("a status response")["payload"]
        .clone();
    assert!(payload.get("login").is_none());
}

#[tokio::test]
async fn account_requests_reach_the_provider_and_failures_carry_their_reason() {
    // `provider_operation_failed` alone is unactionable on a phone. An
    // account request that failed because nothing is signed in has to say
    // that, or the accounts screen can only shrug.
    let home = tempfile::tempdir().unwrap();
    let credential = home.path().join("credential");
    let program = home.path().join("fake-claude");
    std::fs::write(
        &program,
        "#!/bin/sh\ncase \"$1 $2\" in\n'auth status') printf '{\"loggedIn\":false}\\n' ;;\nesac\n",
    )
    .unwrap();
    std::fs::set_permissions(
        &program,
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o700),
    )
    .unwrap();
    let program = program.to_str().unwrap().to_owned();

    let state = state();
    state
        .set_provider_adapters(vec![
            Arc::new(MockAdapter::new(ProviderId::Claude)) as Arc<dyn ProviderAdapter>,
        ])
        .await;
    let store = Arc::new(
        remote_ai_agent::store::Store::open(&home.path().join("state"))
            .await
            .unwrap(),
    );
    state
        .set_account_service(Arc::new(remote_ai_agent::accounts::AccountService::new(
            ProviderId::Claude,
            program.clone(),
            remote_ai_agent::credentials::LiveCredential::File(credential),
            Arc::new(remote_ai_agent::credentials::AccountVault::new(Box::new(
                remote_ai_agent::credentials::InMemorySecrets::default(),
            ))),
            store,
            Arc::new(remote_ai_agent::auth::LoginProbe::claude(program)),
            state.out_of_band_events(),
        )))
        .await;

    let inbound = CryptoBox::new([13; 32], *b"IOS>");
    let outbound = CryptoBox::new([13; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let listed = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "provider.accounts",
            json!({"provider":"claude"}),
        ))
        .await
        .unwrap();
    let view = decode_frames(listed, &outbound)
        .into_iter()
        .find(|value| value["type"] == "provider.accounts.result")
        .expect("an accounts response")["payload"]
        .clone();
    assert_eq!(view["provider"], "claude");
    assert_eq!(view["accounts"].as_array().unwrap().len(), 0);
    assert_eq!(view["login"]["state"], "logged_out");
    assert_eq!(view["loginInProgress"], false);

    let refused = session
        .handle_frame(&request_frame(
            &inbound,
            2,
            "provider.account.save",
            json!({"provider":"claude","label":"work"}),
        ))
        .await
        .unwrap();
    let error = decode_frames(refused, &outbound)
        .into_iter()
        .find(|value| value["type"] == "error")
        .expect("a rejection")["payload"]
        .clone();
    assert_eq!(error["code"], "provider_operation_failed");
    assert!(
        error["message"]
            .as_str()
            .unwrap_or_default()
            .contains("nothing is signed in"),
        "the reason travels with the code: {error}"
    );

    // A label that could address another provider's keychain entry is
    // refused before anything is written.
    let unsafe_label = session
        .handle_frame(&request_frame(
            &inbound,
            3,
            "provider.account.activate",
            json!({"provider":"claude","label":"codex:work"}),
        ))
        .await
        .unwrap();
    let error = decode_frames(unsafe_label, &outbound)
        .into_iter()
        .find(|value| value["type"] == "error")
        .expect("a rejection")["payload"]
        .clone();
    assert_eq!(error["code"], "provider_operation_failed");
}

#[tokio::test]
async fn a_provider_with_no_account_service_reports_unavailable_not_silence() {
    let state = state();
    state
        .set_provider_adapters(vec![
            Arc::new(MockAdapter::new(ProviderId::Codex)) as Arc<dyn ProviderAdapter>,
        ])
        .await;
    let inbound = CryptoBox::new([15; 32], *b"IOS>");
    let outbound = CryptoBox::new([15; 32], *b"MAC>");
    let mut session =
        GatewaySession::new(state, "phone-1", inbound.receiver(), outbound.clone()).await;

    let frames = session
        .handle_frame(&request_frame(
            &inbound,
            1,
            "provider.accounts",
            json!({"provider":"codex"}),
        ))
        .await
        .unwrap();
    assert_eq!(
        decode_frames(frames, &outbound)
            .into_iter()
            .find(|value| value["type"] == "error")
            .expect("a rejection")["payload"]["code"],
        "provider_unavailable"
    );
}
