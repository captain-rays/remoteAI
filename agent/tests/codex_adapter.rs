use std::path::PathBuf;

use remote_ai_agent::adapters::codex::{CodexAdapter, CodexMapper};
use remote_ai_agent::protocol::{ConversationEvent, ConversationKind, ProviderId};
use serde_json::json;

#[test]
fn maps_sanitized_codex_v2_transcript_without_losing_unknown_events() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let conversations = mapper
        .map_thread_list(include_str!("fixtures/codex/thread-list.jsonl"))
        .unwrap();
    assert_eq!(conversations.len(), 2);
    assert_eq!(conversations[0].provider, ProviderId::Codex);
    assert_eq!(conversations[0].kind, ConversationKind::Daily);
    assert_eq!(conversations[1].kind, ConversationKind::Project);

    let events: Vec<_> = include_str!("fixtures/codex/events.jsonl")
        .lines()
        .map(|line| mapper.map_notification(line).unwrap())
        .collect();
    assert!(matches!(&events[0], ConversationEvent::Delta { text } if text == "hello"));
    assert!(
        matches!(&events[1], ConversationEvent::ApprovalRequested(value) if value["category"] == "command")
    );
    assert!(
        matches!(&events[2], ConversationEvent::ApprovalRequested(value) if value["category"] == "file")
    );
    assert!(matches!(&events[3], ConversationEvent::TurnCompleted(_)));
    assert!(
        matches!(&events[4], ConversationEvent::Unsupported { raw_type, .. } if raw_type == "future/notification")
    );
}

#[test]
fn command_spec_uses_app_server_and_never_bypasses_approvals() {
    let adapter = CodexAdapter::new("/usr/local/bin/codex", "/Users/test");
    let spec = adapter.command_spec();
    assert_eq!(spec.args, ["app-server", "--stdio"]);
    let joined = spec.args.join(" ");
    assert!(!joined.contains("bypass"));
    assert!(!joined.contains("dangerously"));
    assert_eq!(
        adapter.approval_response(true),
        serde_json::json!({"decision": "accept"})
    );
    assert_eq!(
        adapter.approval_response(false),
        serde_json::json!({"decision": "decline"})
    );
}

#[test]
fn json_rpc_response_ids_are_normalized_without_string_quotes() {
    assert_eq!(CodexAdapter::rpc_id_key(&json!("7")), "7");
    assert_eq!(CodexAdapter::rpc_id_key(&json!(8)), "8");
}

#[test]
fn maps_codex_thread_read_to_bounded_shared_history_events() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let page = mapper
        .map_thread_read(
            include_str!("fixtures/codex/thread-read.jsonl"),
            "project-1",
            None,
        )
        .unwrap();
    assert_eq!(page.conversation_id, "project-1");
    assert!(page.next_cursor.is_some());
    assert!(page.events.iter().any(|event| {
        event["type"] == "conversation.user_message" && event["payload"]["text"] == "hello"
    }));
    assert!(page.events.iter().any(|event| {
        event["type"] == "conversation.message_completed" && event["payload"]["text"] == "world"
    }));
    assert!(page.events.iter().any(|event| {
        event["type"] == "conversation.reasoning_completed"
            && event["payload"]["reasoningId"].is_string()
    }));
    assert!(
        page.events
            .iter()
            .any(|event| event["type"] == "tool.started")
    );
    assert!(
        !page
            .events
            .iter()
            .any(|event| event.to_string().contains("apiKey"))
    );
}

#[tokio::test]
#[ignore = "read-only smoke test requires a locally authenticated Codex CLI"]
async fn lists_real_codex_threads_without_modifying_them() {
    use remote_ai_agent::adapters::ProviderAdapter;
    let adapter = CodexAdapter::new("codex", std::env::var("HOME").unwrap());
    let conversations = adapter.list_conversations().await.unwrap();
    assert!(!conversations.is_empty());
}
