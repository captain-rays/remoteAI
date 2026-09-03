use std::path::PathBuf;
use std::time::{Duration, SystemTime};

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
            "--verbose",
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

/// The CLI refuses `--print --output-format stream-json` unless `--verbose` is
/// also passed: it exits 1 with
/// "When using --print, --output-format=stream-json requires --verbose".
/// Verified against claude 2.1.210.
#[test]
fn stream_json_output_requires_verbose() {
    let adapter = ClaudeAdapter::new("/usr/local/bin/claude", "/Users/test");
    for spec in [
        adapter.command_spec(None),
        adapter.command_spec(Some("session-1")),
    ] {
        assert!(
            spec.args.iter().any(|arg| arg == "--print"),
            "adapter must run the CLI non-interactively"
        );
        assert!(
            spec.args.iter().any(|arg| arg == "--verbose"),
            "stream-json output without --verbose makes the CLI exit 1: {:?}",
            spec.args
        );
    }
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

#[tokio::test]
async fn indexes_claude_project_sessions_from_bounded_metadata() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let projects = temp.path().join(".claude/projects");
    std::fs::create_dir_all(projects.join("project-a/nested")).unwrap();
    std::fs::write(temp.path().join(".claude/.credentials.json"), "secret").unwrap();
    std::fs::write(
        temp.path().join(".claude/projects/settings.json"),
        r#"{"token":"must not be read"}"#,
    )
    .unwrap();

    let project_file = projects.join("project-a/nested/session-a.jsonl");
    let daily_file = projects.join("session-b.jsonl");
    std::fs::write(
        &project_file,
        include_str!("fixtures/claude/projects/project-a/session-a.jsonl"),
    )
    .unwrap();
    let daily_fixture = include_str!("fixtures/claude/projects/project-b/session-b.jsonl")
        .replace("__HOME__", temp.path().to_str().unwrap());
    std::fs::write(&daily_file, daily_fixture).unwrap();
    std::fs::File::open(&project_file)
        .unwrap()
        .set_modified(SystemTime::now())
        .unwrap();
    std::fs::File::open(&daily_file)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(60))
        .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    let conversations = adapter.list_conversations().await.unwrap();

    assert_eq!(conversations.len(), 2);
    assert_eq!(conversations[0].id, "session-a");
    assert_eq!(conversations[0].kind, ConversationKind::Project);
    assert_eq!(
        conversations[0].project_path.as_deref(),
        Some("/actual/project-a")
    );
    assert_eq!(conversations[0].title, "Build project alpha");
    assert_eq!(conversations[1].id, "session-b");
    assert_eq!(conversations[1].kind, ConversationKind::Daily);
    assert_eq!(conversations[1].project_path, None);
    assert_eq!(conversations[1].title, "Daily task");
}

#[tokio::test]
async fn history_pages_skip_records_with_nothing_to_show() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project_file = temp
        .path()
        .join(".claude/projects/project-noise/session-noise.jsonl");
    std::fs::create_dir_all(project_file.parent().unwrap()).unwrap();
    // A real Claude transcript is mostly bookkeeping: queue operations and
    // attachments outnumber the turns and render as nothing on the phone.
    let mut lines = vec![
        r#"{"type":"user","sessionId":"session-noise","uuid":"u-1","cwd":"/tmp/noise","message":{"content":[{"type":"text","text":"hello"}]}}"#.to_owned(),
    ];
    for index in 0..10 {
        lines.push(format!(
            r#"{{"type":"queue-operation","sessionId":"session-noise","uuid":"q-{index}"}}"#
        ));
    }
    lines.push(
        r#"{"type":"assistant","sessionId":"session-noise","uuid":"a-1","message":{"content":[{"type":"text","text":"world"}]}}"#
            .to_owned(),
    );
    std::fs::write(&project_file, lines.join("\n")).unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_page_size(3);
    adapter.list_conversations().await.unwrap();

    let page = adapter
        .load_conversation("session-noise", None)
        .await
        .unwrap();

    assert_eq!(
        page.events.len(),
        2,
        "bookkeeping records must not fill a page with blanks: {:?}",
        page.events
    );
    assert_eq!(page.events[0]["type"], "conversation.user_message");
    assert_eq!(page.events[1]["type"], "conversation.message_completed");
    assert_eq!(page.next_cursor, None);
}

#[tokio::test]
async fn a_signature_only_thinking_block_is_not_shown_as_reasoning() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project_file = temp
        .path()
        .join(".claude/projects/project-sig/session-sig.jsonl");
    std::fs::create_dir_all(project_file.parent().unwrap()).unwrap();
    std::fs::write(
        &project_file,
        concat!(
            r#"{"type":"user","sessionId":"session-sig","uuid":"u-1","cwd":"/tmp/sig","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            "\n",
            r#"{"type":"assistant","sessionId":"session-sig","uuid":"a-1","message":{"content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"done"}]}}"#,
        ),
    )
    .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    adapter.list_conversations().await.unwrap();

    let page = adapter
        .load_conversation("session-sig", None)
        .await
        .unwrap();

    assert!(
        !page
            .events
            .iter()
            .any(|event| event["type"] == "conversation.reasoning_completed"),
        "an empty thinking block must not become a reasoning row: {:?}",
        page.events
    );
    assert_eq!(page.events.len(), 2);
}

#[tokio::test]
async fn loads_paged_claude_history_with_normalized_events() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project_file = temp
        .path()
        .join(".claude/projects/project-a/session-a.jsonl");
    std::fs::create_dir_all(project_file.parent().unwrap()).unwrap();
    std::fs::write(
        &project_file,
        include_str!("fixtures/claude/projects/project-a/session-a.jsonl"),
    )
    .unwrap();
    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_page_size(3);
    adapter.list_conversations().await.unwrap();

    let first = adapter.load_conversation("session-a", None).await.unwrap();
    assert_eq!(first.events.len(), 3);
    assert_eq!(first.next_cursor.as_deref(), Some("3"));
    assert_eq!(first.events[0]["type"], "conversation.user_message");
    assert_eq!(first.events[0]["payload"]["messageId"], "user-1");
    assert_eq!(first.events[0]["payload"]["text"], "Build project alpha");
    assert_eq!(first.events[1]["type"], "conversation.reasoning_completed");
    assert_eq!(first.events[1]["payload"]["reasoningId"], "assistant-1");
    assert_eq!(first.events[2]["type"], "conversation.message_completed");
    assert_eq!(first.events[2]["payload"]["text"], "done");

    let second = adapter
        .load_conversation("session-a", first.next_cursor)
        .await
        .unwrap();
    assert_eq!(second.events.len(), 3);
    assert_eq!(second.next_cursor, None);
    assert_eq!(second.events[0]["type"], "tool.started");
    assert_eq!(second.events[1]["type"], "tool.completed");
    assert_eq!(second.events[2]["type"], "turn.completed");
    assert!(
        first
            .events
            .iter()
            .all(|event| !second.events.contains(event))
    );
}
