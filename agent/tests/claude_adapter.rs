use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use remote_ai_agent::adapters::claude::{ClaudeAdapter, ClaudeMapper};
use remote_ai_agent::protocol::{ConversationEvent, ConversationKind, ProviderId, WriteState};

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
async fn indexes_unarchived_claude_desktop_sessions_as_daily() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let desktop_root = temp
        .path()
        .join("Library/Application Support/Claude/local-agent-mode-sessions/account/session");
    std::fs::create_dir_all(&desktop_root).unwrap();
    std::fs::write(
        desktop_root.join("local_session.json"),
        include_str!("fixtures/claude/desktop/local-session.json"),
    )
    .unwrap();
    std::fs::write(
        desktop_root.join("11111111-1111-4111-8111-111111111111.jsonl"),
        r#"{"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","message":{"content":[{"type":"text","text":"hello"}]}}"#,
    )
    .unwrap();
    std::fs::write(
        desktop_root.join("local_archived.json"),
        r#"{"sessionId":"archived","cliSessionId":"22222222-2222-4222-8222-222222222222","title":"Archived","cwd":"/tmp/archived","createdAt":1725400000000,"lastActivityAt":1725400060000,"isArchived":true}"#,
    )
    .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    let conversations = adapter.list_conversations().await.unwrap();

    assert_eq!(conversations.len(), 1);
    assert_eq!(conversations[0].id, "desktop-session-1");
    assert_eq!(conversations[0].kind, ConversationKind::Daily);
    assert_eq!(conversations[0].title, "Desktop daily fixture");
    assert_eq!(conversations[0].project_path, None);

    let page = adapter
        .load_conversation("desktop-session-1", None)
        .await
        .unwrap();
    assert_eq!(page.events[0]["type"], "conversation.user_message");
    assert_eq!(page.events[0]["payload"]["text"], "hello");
}

#[tokio::test]
async fn desktop_catalog_does_not_hide_cli_project_sessions() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::catalog::project_id_for_path;

    let temp = tempfile::tempdir().unwrap();
    let cli_project = temp.path().join("cli-project");
    std::fs::create_dir_all(&cli_project).unwrap();

    // A desktop metadata root is present on real installations. Its presence
    // must not make the adapter return before scanning the CLI project index.
    let desktop_root = temp
        .path()
        .join("Library/Application Support/Claude/claude-code-sessions/account/session");
    std::fs::create_dir_all(&desktop_root).unwrap();
    std::fs::write(
        desktop_root.join("local_desktop.json"),
        r#"{"sessionId":"desktop-1","cliSessionId":"desktop-cli-1","title":"Desktop","cwd":"/tmp/desktop-project","createdAt":1725400000000,"lastActivityAt":1725400060000,"isArchived":false}"#,
    )
    .unwrap();

    let cli_session = temp.path().join(".claude/projects/cli-project/cli-1.jsonl");
    std::fs::create_dir_all(cli_session.parent().unwrap()).unwrap();
    std::fs::write(
        &cli_session,
        format!(
            r#"{{"type":"user","session_id":"cli-1","cwd":"{}","message":{{"content":[{{"type":"text","text":"project query"}}]}}}}"#,
            cli_project.display()
        ),
    )
    .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    let projects = adapter.list_projects().await.unwrap();
    let canonical = cli_project
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let project_id = project_id_for_path(ProviderId::Claude, &canonical);
    assert!(
        projects.iter().any(|project| project.id == project_id),
        "CLI project metadata must remain visible when Desktop metadata also exists: {projects:?}"
    );

    let conversations = adapter
        .list_project_conversations(&project_id)
        .await
        .unwrap();
    assert!(
        conversations
            .iter()
            .any(|conversation| conversation.id == "cli-1"),
        "the CLI project session must be addressable from its project: {conversations:?}"
    );
}

#[tokio::test]
async fn sends_claude_stream_json_user_input_as_a_text_block() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        "#!/bin/sh\nprintf '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"real-input-session\",\"cwd\":\"%s\"}\\n' \"$PWD\"\nIFS= read -r line\nprintf '%s\\n' \"$line\" > \"$0.input\"\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    let id = adapter
        .start(ConversationKind::Project, Some(temp.path().to_path_buf()))
        .await
        .unwrap();
    adapter
        .send(&id, "fixed harmless probe".into(), Vec::new())
        .await
        .unwrap();

    let input_path = stub.with_extension("sh.input");
    let input = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            if let Ok(input) = std::fs::read_to_string(&input_path) {
                break input;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the stub should receive one stream-json user record");
    let value: serde_json::Value = serde_json::from_str(input.trim()).unwrap();
    assert_eq!(value["type"], "user");
    assert_eq!(value["message"]["role"], "user");
    assert_eq!(value["message"]["content"][0]["type"], "text");
    assert_eq!(
        value["message"]["content"][0]["text"],
        "fixed harmless probe"
    );
}

#[tokio::test]
async fn a_started_project_session_runs_in_that_project_and_adopts_its_real_id() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::protocol::{ConversationEvent, ConversationKind};

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("project-alpha");
    std::fs::create_dir_all(&project).unwrap();

    // A stub CLI that reports the directory it was actually started in, the
    // way Claude's stream-json init record does.
    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        "#!/bin/sh\nprintf '{\"type\":\"system\",\"subtype\":\"init\",\
\"session_id\":\"real-session-1\",\"cwd\":\"%s\"}\\n' \"$PWD\"\ncat > /dev/null\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    let mut events = adapter.subscribe();
    let id = adapter
        .start(ConversationKind::Project, Some(project.clone()))
        .await
        .unwrap();

    let started = tokio::time::timeout(std::time::Duration::from_secs(5), events.recv())
        .await
        .expect("the stub should report its startup")
        .expect("event");
    let ConversationEvent::Started(payload) = started else {
        panic!("expected a started event, got {started:?}");
    };
    assert_eq!(
        payload.get("cwd").and_then(|value| value.as_str()),
        Some(project.canonicalize().unwrap().to_string_lossy().as_ref()),
        "the CLI must run in the project the phone chose"
    );

    // The provider's own id must replace the placeholder, or the Mac and the
    // phone are looking at two different sessions.
    let resolved = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let Some(real) = adapter.resolved_session_id(&id).await {
                return real;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the placeholder id should resolve");
    assert_eq!(resolved, "real-session-1");

    // Reading the placeholder must reach the transcript Claude wrote, so the
    // screen the phone already has open fills in.
    std::fs::create_dir_all(temp.path().join(".claude/projects/project-alpha")).unwrap();
    std::fs::write(
        temp.path()
            .join(".claude/projects/project-alpha/real-session-1.jsonl"),
        format!(
            r#"{{"type":"user","sessionId":"real-session-1","uuid":"u-1","cwd":"{}","message":{{"content":[{{"type":"text","text":"hi"}}]}}}}"#,
            project.display()
        ),
    )
    .unwrap();
    adapter.list_conversations().await.unwrap();

    let page = adapter.load_conversation(&id, None).await.unwrap();
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0]["type"], "conversation.user_message");
}

#[tokio::test]
async fn sending_to_an_indexed_session_resumes_it_instead_of_failing() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("project-beta");
    std::fs::create_dir_all(&project).unwrap();
    let sessions = temp.path().join(".claude/projects/project-beta");
    std::fs::create_dir_all(&sessions).unwrap();
    std::fs::write(
        sessions.join("session-beta.jsonl"),
        format!(
            r#"{{"type":"user","sessionId":"session-beta","uuid":"u-1","cwd":"{}","message":{{"content":[{{"type":"text","text":"earlier"}}]}}}}"#,
            project.display()
        ),
    )
    .unwrap();

    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(&stub, "#!/bin/sh\ncat > /dev/null\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    adapter.list_conversations().await.unwrap();

    // Nothing started this session in this agent run: the phone is picking up
    // a conversation that already existed on the Mac.
    adapter
        .send("session-beta", "hello".into(), Vec::new())
        .await
        .expect("an indexed session must accept a message");

    assert!(
        adapter
            .send("never-indexed", "hello".into(), Vec::new())
            .await
            .is_err(),
        "an unknown conversation is still an error"
    );
}

#[tokio::test]
async fn a_session_this_agent_holds_for_the_phone_stays_writable() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("project-active");
    std::fs::create_dir_all(&project).unwrap();

    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(&stub, "#!/bin/sh\ncat > /dev/null\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    let id = adapter
        .start(ConversationKind::Project, Some(project))
        .await
        .unwrap();
    adapter
        .send(&id, "fixed-probe".into(), Vec::new())
        .await
        .unwrap();

    // The gateway refuses `conversation.send` whenever the adapter answers
    // Busy, so a writer this agent opened *on the phone's behalf* must stay
    // Available — otherwise the phone could never send a second message.
    // Busy is reserved for a writer the phone does not own.
    assert_eq!(
        adapter.write_availability(&id).await.unwrap(),
        WriteState::Available,
        "the phone's own live session must accept a follow-up message"
    );
    adapter
        .send(&id, "second-probe".into(), Vec::new())
        .await
        .expect("a second message to the same session must be accepted");
}

#[tokio::test]
async fn started_claude_session_emits_delta_and_terminal_for_first_send() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("project-turn");
    std::fs::create_dir_all(&project).unwrap();

    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"real-turn-1\",\"cwd\":\"'$PWD'\"}'\nIFS= read -r _\nprintf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"fixed-reply\"}}}'\nprintf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"real-turn-1\",\"is_error\":false}'\ncat >/dev/null\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    let mut events = adapter.subscribe();
    let id = adapter
        .start(ConversationKind::Project, Some(project))
        .await
        .unwrap();
    adapter
        .send(&id, "fixed-probe".into(), Vec::new())
        .await
        .unwrap();

    let mut saw_delta = false;
    let mut saw_terminal = false;
    for _ in 0..4 {
        let event = tokio::time::timeout(std::time::Duration::from_secs(10), events.recv())
            .await
            .expect("first send should produce a bounded event")
            .expect("event stream should remain open");
        saw_delta |=
            matches!(event, ConversationEvent::Delta { ref text } if text == "fixed-reply");
        saw_terminal |= matches!(event, ConversationEvent::TurnCompleted(_));
        if saw_delta && saw_terminal {
            break;
        }
    }
    assert!(
        saw_delta,
        "the first Claude send must emit an assistant delta"
    );
    assert!(
        saw_terminal,
        "the first Claude send must emit a terminal event"
    );
}

#[tokio::test]
async fn a_started_project_session_rejects_a_directory_that_is_not_there() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::protocol::ConversationKind;

    let temp = tempfile::tempdir().unwrap();
    let adapter = ClaudeAdapter::new("/usr/bin/true", temp.path());

    assert!(
        adapter
            .start(ConversationKind::Project, Some(temp.path().join("missing")))
            .await
            .is_err(),
        "a project directory that does not exist must not start a session"
    );
}

#[tokio::test]
async fn a_session_started_here_reads_back_as_empty_history() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::protocol::ConversationKind;

    let temp = tempfile::tempdir().unwrap();
    // `true` exits immediately: this test is about a started session that has
    // not written a transcript yet, not about talking to Claude.
    let adapter = ClaudeAdapter::new("/usr/bin/true", temp.path());
    let id = adapter.start(ConversationKind::Daily, None).await.unwrap();

    let page = adapter.load_conversation(&id, None).await.unwrap();

    assert!(page.events.is_empty());
    assert_eq!(page.next_cursor, None);
    assert_eq!(page.conversation_id, id);

    assert!(
        adapter.load_conversation("never-seen", None).await.is_err(),
        "an unknown conversation is still an error"
    );
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

    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_turns(3);
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
async fn loads_claude_history_as_normalized_events() {
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
    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_turns(3);
    adapter.list_conversations().await.unwrap();

    // This fixture is one complete exchange, so it is one page however small
    // the turn budget is: a page never cuts a turn in half.
    let page = adapter.load_conversation("session-a", None).await.unwrap();
    assert_eq!(page.next_cursor, None);
    assert_eq!(
        page.events
            .iter()
            .map(|event| event["type"].as_str().unwrap_or_default())
            .collect::<Vec<_>>(),
        [
            "conversation.user_message",
            "conversation.reasoning_completed",
            "conversation.message_completed",
            "tool.started",
            "tool.completed",
            "turn.completed",
        ],
        "the page reads oldest-first: {:?}",
        page.events
    );
    assert_eq!(page.events[0]["payload"]["messageId"], "user-1");
    assert_eq!(page.events[0]["payload"]["text"], "Build project alpha");
    assert_eq!(page.events[1]["payload"]["reasoningId"], "assistant-1");
    assert_eq!(page.events[2]["payload"]["text"], "done");
}

#[tokio::test]
async fn a_cli_session_is_reachable_from_chats_or_from_its_project() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::catalog::project_id_for_path;

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("cli-project");
    std::fs::create_dir_all(&project).unwrap();
    // A desktop root exists on every real installation.
    std::fs::create_dir_all(
        temp.path()
            .join("Library/Application Support/Claude/claude-code-sessions"),
    )
    .unwrap();

    let sessions = temp.path().join(".claude/projects/scan");
    std::fs::create_dir_all(&sessions).unwrap();
    std::fs::write(
        sessions.join("home-session.jsonl"),
        format!(
            r#"{{"type":"user","session_id":"home-session","cwd":"{}","message":{{"content":[{{"type":"text","text":"a chat"}}]}}}}"#,
            temp.path().display()
        ),
    )
    .unwrap();
    std::fs::write(
        sessions.join("project-session.jsonl"),
        format!(
            r#"{{"type":"user","session_id":"project-session","cwd":"{}","message":{{"content":[{{"type":"text","text":"project work"}}]}}}}"#,
            project.display()
        ),
    )
    .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    let chats = adapter.list_daily_conversations().await.unwrap();
    let canonical = project
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let project_conversations = adapter
        .list_project_conversations(&project_id_for_path(ProviderId::Claude, &canonical))
        .await
        .unwrap();

    assert_eq!(
        chats
            .iter()
            .map(|chat| chat.id.as_str())
            .collect::<Vec<_>>(),
        ["home-session"],
        "Chats holds the sessions that are not bound to a project directory"
    );
    assert_eq!(
        project_conversations
            .iter()
            .map(|conversation| conversation.id.as_str())
            .collect::<Vec<_>>(),
        ["project-session"],
        "a directory-bound CLI session is reachable from its project"
    );
}

#[tokio::test]
async fn a_new_chat_runs_in_the_paired_home_not_the_agent_directory() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    // Record the directory the CLI was launched in. Claude files a session
    // under its process cwd, which is what decides whether it is a chat or a
    // project session. The path is baked into the script rather than passed
    // through the environment, which is process-global and races other tests.
    let probe = temp.path().join("cwd.txt");
    let stub = home.join("fake-claude.sh");
    std::fs::write(
        &stub,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$PWD\" > '{probe}'\nwhile IFS= read -r _; do :; done\n",
            probe = probe.display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, &home);
    adapter.start(ConversationKind::Daily, None).await.unwrap();

    let recorded = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            if let Ok(recorded) = std::fs::read_to_string(&probe)
                && !recorded.trim().is_empty()
            {
                break recorded;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the stub should record the directory it ran in");
    assert_eq!(
        std::fs::canonicalize(recorded.trim()).unwrap(),
        std::fs::canonicalize(&home).unwrap(),
        "a chat is not bound to a project, so it runs in the paired user's HOME"
    );
}

#[tokio::test]
async fn resuming_an_indexed_session_runs_in_the_directory_it_was_recorded_in() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let recorded_cwd = temp.path().join("recorded");
    std::fs::create_dir_all(&recorded_cwd).unwrap();
    // A desktop root exists on every real installation, and the agent process
    // itself runs somewhere else entirely.
    std::fs::create_dir_all(
        temp.path()
            .join("Library/Application Support/Claude/claude-code-sessions"),
    )
    .unwrap();

    let sessions = temp.path().join(".claude/projects/slug");
    std::fs::create_dir_all(&sessions).unwrap();
    std::fs::write(
        sessions.join("indexed.jsonl"),
        format!(
            r#"{{"type":"user","session_id":"indexed","cwd":"{}","message":{{"content":[{{"type":"text","text":"earlier work"}}]}}}}"#,
            recorded_cwd.display()
        ),
    )
    .unwrap();

    // `--resume` resolves a session id only inside the directory the session
    // was recorded in, so record both the arguments and the launch directory.
    let probe = temp.path().join("resume.txt");
    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '{probe}'\nwhile IFS= read -r _; do :; done\n",
            probe = probe.display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let adapter = ClaudeAdapter::new(&stub, temp.path());
    adapter.list_conversations().await.unwrap();
    adapter
        .send("indexed", "a follow-up from the phone".into(), Vec::new())
        .await
        .unwrap();

    let recorded = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            if let Ok(recorded) = std::fs::read_to_string(&probe)
                && recorded.lines().count() > 1
            {
                break recorded;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the stub should record how it was launched");

    let lines = recorded.lines().collect::<Vec<_>>();
    assert_eq!(
        std::fs::canonicalize(lines[0]).unwrap(),
        std::fs::canonicalize(&recorded_cwd).unwrap(),
        "resuming outside the session's own directory makes the CLI exit with \
         \"No conversation found with session ID\""
    );
    assert!(
        lines.windows(2).any(|pair| pair == ["--resume", "indexed"]),
        "the session must be resumed by its own id: {lines:?}"
    );
}

#[tokio::test]
async fn a_dead_claude_process_is_replaced_on_the_next_send() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    // One marker file per launch, so counting launches needs no shell state.
    let launches = temp.path().join("launches");
    std::fs::create_dir_all(&launches).unwrap();

    // The first process exits immediately, the way a crashed CLI does. A held
    // handle to it can never carry another message, so the adapter has to
    // notice and start a new one instead of failing every later send.
    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        format!(
            "#!/bin/sh\nmarker='{launches}'/$$\n: > \"$marker\"\ncount=$(ls '{launches}' | wc -l)\nif [ \"$count\" -le 1 ]; then\n  exit 1\nfi\nwhile IFS= read -r _; do :; done\n",
            launches = launches.display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let count_launches = || std::fs::read_dir(&launches).unwrap().count();
    let adapter = ClaudeAdapter::new(&stub, temp.path());
    let id = adapter
        .start(ConversationKind::Project, Some(project))
        .await
        .unwrap();
    // Wait for the first process to record its launch and exit.
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        while count_launches() == 0 {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the first CLI launch should be recorded");
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;

    adapter
        .send(&id, "a message after the crash".into(), Vec::new())
        .await
        .expect("a send after the CLI died must start a new one");

    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        while count_launches() < 2 {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the adapter kept writing to the dead process instead of replacing it");
}

/// Build a HOME with a desktop catalog that designates one project, plus CLI
/// sessions in a worktree under it, in an undesignated directory inside HOME,
/// and in a directory outside HOME entirely.
struct NestedFixture {
    designated: PathBuf,
    nested: PathBuf,
    undesignated: PathBuf,
    outside: PathBuf,
    _outside_root: tempfile::TempDir,
}

fn write_nested_cli_sessions(root: &std::path::Path) -> NestedFixture {
    let designated = root.join("designated");
    let nested = designated.join("worktrees/one");
    let undesignated = root.join("terminal-only");
    let outside_root = tempfile::tempdir().unwrap();
    let outside = outside_root.path().join("scratch");
    for path in [&designated, &nested, &undesignated, &outside] {
        std::fs::create_dir_all(path).unwrap();
    }

    let desktop = root.join("Library/Application Support/Claude/claude-code-sessions/acct/s");
    std::fs::create_dir_all(&desktop).unwrap();
    std::fs::write(
        desktop.join("local_designated.json"),
        format!(
            r#"{{"sessionId":"desktop-1","cliSessionId":"cli-desktop","title":"Designated","cwd":"{}","createdAt":1725400000000,"lastActivityAt":1725400060000,"isArchived":false}}"#,
            designated.display()
        ),
    )
    .unwrap();

    let sessions = root.join(".claude/projects/slug");
    std::fs::create_dir_all(&sessions).unwrap();
    for (id, cwd) in [
        ("nested-session", &nested),
        ("terminal-session", &undesignated),
        ("outside-session", &outside),
    ] {
        std::fs::write(
            sessions.join(format!("{id}.jsonl")),
            format!(
                r#"{{"type":"user","session_id":"{id}","cwd":"{}","message":{{"content":[{{"type":"text","text":"{id}"}}]}}}}"#,
                cwd.display()
            ),
        )
        .unwrap();
    }
    NestedFixture {
        designated,
        nested,
        undesignated,
        outside,
        _outside_root: outside_root,
    }
}

fn canonical(path: &std::path::Path) -> String {
    path.canonicalize().unwrap().to_string_lossy().into_owned()
}

#[tokio::test]
async fn a_subdirectory_of_a_project_is_not_a_separate_project() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    let fixture = write_nested_cli_sessions(temp.path());
    let adapter = ClaudeAdapter::new("claude", temp.path());

    let projects = adapter.list_projects().await.unwrap();
    let paths = projects
        .iter()
        .map(|project| project.canonical_path.clone())
        .collect::<Vec<_>>();

    assert!(
        !paths.contains(&canonical(&fixture.nested)),
        "a worktree inside a project is not a project of its own: {paths:?}"
    );
    assert!(
        !paths.contains(&canonical(&fixture.outside)),
        "a directory outside the paired user's HOME cannot be browsed, so it          is not offered as a project: {paths:?}"
    );
    assert!(
        paths.contains(&canonical(&fixture.designated)),
        "the designated directory is a project: {paths:?}"
    );
    assert!(
        paths.contains(&canonical(&fixture.undesignated)),
        "a directory only the terminal has worked in is still a project, or          that work would be unreachable from the Projects tab: {paths:?}"
    );
    assert_eq!(
        paths.len(),
        2,
        "no other directory became a project: {paths:?}"
    );
}

#[tokio::test]
async fn a_session_inside_a_project_is_listed_under_that_project() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use remote_ai_agent::catalog::project_id_for_path;

    let temp = tempfile::tempdir().unwrap();
    let fixture = write_nested_cli_sessions(temp.path());
    let adapter = ClaudeAdapter::new("claude", temp.path());

    let conversations = adapter
        .list_project_conversations(&project_id_for_path(
            ProviderId::Claude,
            &canonical(&fixture.designated),
        ))
        .await
        .unwrap();

    let ids = conversations
        .iter()
        .map(|conversation| conversation.id.as_str())
        .collect::<Vec<_>>();
    assert!(
        ids.contains(&"nested-session"),
        "a session in a worktree belongs to the project that encloses it: {ids:?}"
    );
    assert!(ids.contains(&"desktop-1"), "{ids:?}");
    assert!(!ids.contains(&"terminal-session"), "{ids:?}");
}

#[tokio::test]
async fn a_session_no_project_encloses_is_still_reachable_from_chats() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    write_nested_cli_sessions(temp.path());
    let adapter = ClaudeAdapter::new("claude", temp.path());

    let chats = adapter.list_daily_conversations().await.unwrap();
    let ids = chats
        .iter()
        .map(|chat| chat.id.as_str())
        .collect::<Vec<_>>();
    assert!(
        ids.contains(&"outside-session"),
        "a session no project encloses has no project view, so Chats is the \
         only place it can be reached from: {ids:?}"
    );
    for owned in ["nested-session", "terminal-session"] {
        assert!(
            !ids.contains(&owned),
            "{owned} has a project view and must not also crowd Chats: {ids:?}"
        );
    }
}

#[tokio::test]
async fn without_a_desktop_catalog_cli_session_directories_are_the_projects() {
    use remote_ai_agent::adapters::ProviderAdapter;

    // A Mac that only ever used the CLI has no designated directories at all.
    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("cli-only");
    std::fs::create_dir_all(&project).unwrap();
    let sessions = temp.path().join(".claude/projects/slug");
    std::fs::create_dir_all(&sessions).unwrap();
    std::fs::write(
        sessions.join("only.jsonl"),
        format!(
            r#"{{"type":"user","session_id":"only","cwd":"{}","message":{{"content":[{{"type":"text","text":"work"}}]}}}}"#,
            project.display()
        ),
    )
    .unwrap();

    let adapter = ClaudeAdapter::new("claude", temp.path());
    let projects = adapter.list_projects().await.unwrap();

    assert_eq!(
        projects
            .iter()
            .map(|project| project.canonical_path.as_str())
            .collect::<Vec<_>>(),
        [canonical(&project).as_str()]
    );
}

/// Write a transcript of `turns` complete exchanges, each one user message
/// followed by a tool call, its result and an assistant reply.
fn write_claude_turns(root: &std::path::Path, session: &str, turns: usize) {
    let path = root
        .join(".claude/projects/paging")
        .join(format!("{session}.jsonl"));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut lines = vec![format!(
        r#"{{"type":"system","subtype":"init","sessionId":"{session}","cwd":"{}"}}"#,
        root.display()
    )];
    for turn in 1..=turns {
        lines.push(format!(
            r#"{{"type":"user","sessionId":"{session}","uuid":"u-{turn}","cwd":"{}","message":{{"content":[{{"type":"text","text":"ask {turn}"}}]}}}}"#,
            root.display()
        ));
        lines.push(format!(
            r#"{{"type":"assistant","sessionId":"{session}","uuid":"t-{turn}","message":{{"content":[{{"type":"tool_use","id":"tool-{turn}","name":"Bash","input":{{}}}}]}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"user","sessionId":"{session}","uuid":"r-{turn}","message":{{"content":[{{"type":"tool_result","tool_use_id":"tool-{turn}","content":"out {turn}"}}]}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"assistant","sessionId":"{session}","uuid":"a-{turn}","message":{{"content":[{{"type":"text","text":"answer {turn}"}}]}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"result","subtype":"success","sessionId":"{session}","is_error":false}}"#
        ));
    }
    std::fs::write(&path, lines.join("\n")).unwrap();
}

fn user_texts(events: &[serde_json::Value]) -> Vec<String> {
    events
        .iter()
        .filter(|event| event["type"] == "conversation.user_message")
        .map(|event| {
            event["payload"]["text"]
                .as_str()
                .unwrap_or_default()
                .to_owned()
        })
        .collect()
}

#[tokio::test]
async fn claude_history_opens_on_the_newest_turns_and_pages_backwards() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    write_claude_turns(temp.path(), "paged", 7);
    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_turns(3);
    adapter.list_conversations().await.unwrap();

    let first = adapter.load_conversation("paged", None).await.unwrap();
    assert_eq!(
        user_texts(&first.events),
        ["ask 5", "ask 6", "ask 7"],
        "the transcript opens on the newest turns, still oldest-first inside \
         the page: {:?}",
        first.events
    );

    let second = adapter
        .load_conversation("paged", first.next_cursor.clone())
        .await
        .unwrap();
    assert_eq!(user_texts(&second.events), ["ask 2", "ask 3", "ask 4"]);

    let third = adapter
        .load_conversation("paged", second.next_cursor.clone())
        .await
        .unwrap();
    assert_eq!(user_texts(&third.events), ["ask 1"]);
    assert_eq!(third.next_cursor, None, "the oldest page ends the walk");
}

#[tokio::test]
async fn a_claude_turn_is_never_split_across_history_pages() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    write_claude_turns(temp.path(), "whole", 5);
    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_turns(2);
    adapter.list_conversations().await.unwrap();

    let mut cursor = None;
    let mut pages = 0;
    loop {
        let page = adapter
            .load_conversation("whole", cursor.clone())
            .await
            .unwrap();
        pages += 1;
        assert_eq!(
            page.events.first().map(|event| &event["type"]),
            Some(&serde_json::json!("conversation.user_message")),
            "a page starts at a turn boundary: {:?}",
            page.events
        );
        // Every turn in the page carries its whole exchange.
        let turns = user_texts(&page.events).len();
        assert_eq!(
            page.events
                .iter()
                .filter(|event| event["type"] == "turn.completed")
                .count(),
            turns,
            "a page ends on a completed turn: {:?}",
            page.events
        );
        match page.next_cursor {
            Some(next) => cursor = Some(next),
            None => break,
        }
        assert!(pages < 10, "paging must terminate");
    }
    assert_eq!(pages, 3, "five turns at two per page is three pages");
}

#[tokio::test]
async fn a_claude_history_cursor_survives_a_turn_arriving_while_paging() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let temp = tempfile::tempdir().unwrap();
    write_claude_turns(temp.path(), "growing", 6);
    let adapter = ClaudeAdapter::new("claude", temp.path()).with_history_turns(2);
    adapter.list_conversations().await.unwrap();

    let first = adapter.load_conversation("growing", None).await.unwrap();
    assert_eq!(user_texts(&first.events), ["ask 5", "ask 6"]);

    // The Mac keeps working while the phone is scrolled up.
    write_claude_turns(temp.path(), "growing", 8);
    let second = adapter
        .load_conversation("growing", first.next_cursor)
        .await
        .unwrap();
    assert_eq!(
        user_texts(&second.events),
        ["ask 3", "ask 4"],
        "the page before the one already shown must not repeat a turn"
    );
}

#[tokio::test]
#[ignore = "read-only smoke test against this Mac's real Claude sessions"]
async fn reports_the_first_history_page_of_a_real_session() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let home = std::env::var("HOME").unwrap();
    let adapter = ClaudeAdapter::new("claude", &home);
    let projects = adapter.list_projects().await.unwrap();
    let project = projects.first().expect("a Claude project");
    let conversations = adapter
        .list_project_conversations(&project.id)
        .await
        .unwrap();
    let conversation = conversations.first().expect("a session in that project");

    let page = adapter
        .load_conversation(&conversation.id, None)
        .await
        .unwrap();
    let turns = page
        .events
        .iter()
        .filter(|event| event["type"] == "conversation.user_message")
        .count();
    println!(
        "REAL_HISTORY project={} session={} events={} turns={} next={:?}",
        project.display_path,
        conversation.id,
        page.events.len(),
        turns,
        page.next_cursor
    );
    assert!(turns <= 5, "a page carries at most five turns");
}
