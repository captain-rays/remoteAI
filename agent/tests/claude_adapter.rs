use std::path::PathBuf;

use remote_ai_agent::adapters::claude::{ClaudeAdapter, ClaudeMapper};
use remote_ai_agent::protocol::{ConversationEvent, ConversationKind, ProviderId};

#[test]
fn maps_stream_json_lifecycle_and_unknown_events() {
    let mapper = ClaudeMapper::new(PathBuf::from("/Users/test"));
    let lines: Vec<_> = include_str!("fixtures/claude/events.jsonl")
        .lines()
        .map(|line| mapper.map_line(line).unwrap())
        .collect();
    assert!(
        matches!(&lines[0], ConversationEvent::Started(value) if value["sessionId"] == "session-1")
    );
    assert!(matches!(&lines[1], ConversationEvent::Delta { text } if text == "hello"));
    assert!(matches!(&lines[2], ConversationEvent::ToolStarted(value) if value["tool"] == "Bash"));
    assert!(
        matches!(&lines[3], ConversationEvent::ApprovalRequested(value) if value["category"] == "command")
    );
    assert!(matches!(&lines[4], ConversationEvent::ToolCompleted(_)));
    assert!(matches!(&lines[5], ConversationEvent::TurnCompleted(_)));
    assert!(matches!(&lines[6], ConversationEvent::TurnFailed(_)));
    assert!(
        matches!(&lines[7], ConversationEvent::Unsupported { raw_type, .. } if raw_type == "future_event")
    );
}

#[test]
fn command_spec_requires_manual_permissions_and_resume_is_explicit() {
    let adapter = ClaudeAdapter::new("/usr/local/bin/claude", "/Users/test");
    let start = adapter.command_spec(None);
    assert_eq!(
        start.args,
        [
            "--print",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--include-hook-events",
            "--permission-mode",
            "manual"
        ]
    );
    let resume = adapter.command_spec(Some("session-1"));
    assert!(
        resume
            .args
            .ends_with(&["--resume".into(), "session-1".into()])
    );
    let joined = start.args.join(" ");
    assert!(!joined.contains("dangerously-skip-permissions"));
}

#[test]
fn classifies_home_as_daily_and_other_paths_as_project() {
    let mapper = ClaudeMapper::new(PathBuf::from("/Users/test"));
    assert_eq!(
        mapper.classify(PathBuf::from("/Users/test")),
        ConversationKind::Daily
    );
    assert_eq!(
        mapper.classify(PathBuf::from("/tmp/project")),
        ConversationKind::Project
    );
    assert_eq!(ProviderId::Claude, ProviderId::Claude);
}

#[tokio::test]
#[ignore = "read-only smoke test requires a locally authenticated Claude CLI"]
async fn lists_real_claude_sessions_without_modifying_them() {
    use remote_ai_agent::adapters::ProviderAdapter;
    let adapter = ClaudeAdapter::new("claude", std::env::var("HOME").unwrap());
    let _ = adapter.list_conversations().await.unwrap();
}
