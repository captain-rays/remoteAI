use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use chrono::{TimeZone, Utc};
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
    assert!(
        conversations[1].project_id.is_none(),
        "thread/list must not invent a path-derived project identity"
    );

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
    // One complete exchange is one page, however small the turn budget is.
    assert_eq!(page.next_cursor, None);
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

#[test]
fn maps_codex_recent_session_index_entries_as_daily_conversations() {
    let mapper = CodexMapper::new(PathBuf::from("/tmp/codex-home"));
    let summary = mapper
        .map_session_index_line(
            r#"{"id":"daily-1","thread_name":"供应链系统名称整理","updated_at":"2026-09-04T08:30:00Z"}"#,
        )
        .unwrap();

    assert_eq!(summary.id, "daily-1");
    assert_eq!(summary.provider, ProviderId::Codex);
    assert_eq!(summary.kind, ConversationKind::Daily);
    assert_eq!(summary.title, "供应链系统名称整理");
    assert!(summary.project_id.is_none());
    assert!(summary.project_path.is_none());
    assert_eq!(summary.updated_at.to_rfc3339(), "2026-09-04T08:30:00+00:00");
}

#[test]
fn recent_session_index_skips_malformed_metadata_and_sorts_newest_first() {
    let mapper = CodexMapper::new(PathBuf::from("/tmp/codex-home"));
    let entries = mapper.map_session_index(
        r#"{"id":"older","thread_name":"older","updated_at":"2026-09-01T00:00:00Z"}
not-json
{"id":"newer","thread_name":"newer","updated_at":"2026-09-04T00:00:00Z"}
{"thread_name":"missing id","updated_at":"2026-09-05T00:00:00Z"}"#,
    );

    assert_eq!(
        entries
            .iter()
            .map(|entry| entry.id.as_str())
            .collect::<Vec<_>>(),
        ["newer", "older"]
    );
}

#[test]
fn recent_session_index_upsert_updates_timestamp_without_writing_prompt() {
    let updated = Utc.with_ymd_and_hms(2026, 9, 4, 9, 0, 0).unwrap();
    let content = r#"{"id":"daily-1","thread_name":"原有标题","updated_at":"2026-09-04T08:30:00Z"}
{"id":"daily-2","thread_name":"另一个会话","updated_at":"2026-09-03T08:00:00Z"}"#;

    let result = CodexMapper::upsert_session_index_content(content, "daily-1", updated);
    let entries = CodexMapper::new(PathBuf::from("/tmp/codex-home")).map_session_index(&result);

    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].id, "daily-1");
    assert_eq!(entries[0].title, "原有标题");
    assert_eq!(entries[0].updated_at, updated);
    assert!(!result.contains("prompt"));
}

#[test]
fn recent_session_index_upsert_adds_new_daily_metadata_entry() {
    let updated = Utc.with_ymd_and_hms(2026, 9, 4, 9, 0, 0).unwrap();
    let result = CodexMapper::upsert_session_index_content("", "new-daily", updated);
    let summary = CodexMapper::new(PathBuf::from("/tmp/codex-home"))
        .map_session_index(&result)
        .into_iter()
        .next()
        .unwrap();

    assert_eq!(summary.id, "new-daily");
    assert_eq!(summary.kind, ConversationKind::Daily);
    assert_eq!(summary.title, "New Codex conversation");
}

#[test]
fn recent_session_index_writer_is_atomic_and_owner_only() {
    let root = tempfile::tempdir().unwrap();
    let mapper = CodexMapper::new(root.path().to_path_buf());
    let updated = Utc.with_ymd_and_hms(2026, 9, 4, 9, 0, 0).unwrap();

    mapper
        .write_session_index_entry("new-daily", updated)
        .unwrap();

    let path = root.path().join(".codex/session_index.jsonl");
    let metadata = std::fs::metadata(&path).unwrap();
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    let entries = mapper.map_session_index(&std::fs::read_to_string(path).unwrap());
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, "new-daily");
}

#[tokio::test]
async fn a_daily_start_that_cannot_reach_the_cli_writes_no_recent_entry() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let adapter = CodexAdapter::new("/definitely/missing/codex", root.path());
    adapter
        .start(ConversationKind::Daily, None)
        .await
        .expect_err("an unreachable CLI cannot start a chat");
    let index = root.path().join(".codex/session_index.jsonl");
    assert!(
        !index.exists(),
        "a failed start must not leave a recent-session entry behind"
    );
}

#[tokio::test]
async fn lists_codex_projects_from_state_database_without_needing_threads() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

    let root = tempfile::tempdir().unwrap();
    let codex_dir = root.path().join(".codex");
    std::fs::create_dir_all(&codex_dir).unwrap();
    let db_path = codex_dir.join("state_5.sqlite");
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(&db_path)
                .create_if_missing(true),
        )
        .await
        .unwrap();
    sqlx::query(
        "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, position INTEGER NOT NULL)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO projects VALUES ('p1','remoteAICli',2000,0),('p2','cockpit',1000,1)")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO project_roots VALUES ('p1',0,'/tmp/remoteAICli'),('p2',0,'/tmp/cockpit')",
    )
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;

    let adapter = CodexAdapter::new("codex", root.path());
    let projects = adapter.list_projects().await.unwrap();
    assert_eq!(projects.len(), 2);
    assert_eq!(projects[0].title, "remoteAICli");
    assert_eq!(projects[0].canonical_path, "/tmp/remoteAICli");
    assert_eq!(projects[0].id, "p1");
}

#[tokio::test]
#[ignore = "read-only smoke test requires a locally authenticated Codex CLI"]
async fn lists_real_codex_threads_without_modifying_them() {
    use remote_ai_agent::adapters::ProviderAdapter;
    let adapter = CodexAdapter::new("codex", std::env::var("HOME").unwrap());
    let conversations = adapter.list_conversations().await.unwrap();
    assert!(!conversations.is_empty());
}

#[tokio::test]
#[ignore = "read-only smoke test requires a locally authenticated Codex CLI and session index"]
async fn lists_real_codex_recent_daily_sessions() {
    use remote_ai_agent::adapters::ProviderAdapter;
    let adapter = CodexAdapter::new("codex", std::env::var("HOME").unwrap());
    let conversations = adapter.list_conversations().await.unwrap();
    assert!(
        conversations
            .iter()
            .any(|conversation| conversation.kind == ConversationKind::Daily)
    );
}

/// Write an executable stub that speaks the subset of the Codex app-server
/// JSON-RPC protocol this adapter uses. `script` is Python appended to a
/// dispatcher that already parsed one request into `method`, `params` and `id`.
fn write_app_server_stub(path: &std::path::Path, script: &str) {
    let stub = format!(
        r#"#!/usr/bin/env python3
import json, sys

def reply(request_id, result):
    sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": result}}) + "\n")
    sys.stdout.flush()

def fail(request_id, message):
    sys.stdout.write(
        json.dumps({{"jsonrpc": "2.0", "id": request_id, "error": {{"code": -32600, "message": message}}}})
        + "\n"
    )
    sys.stdout.flush()

def notify(method, params):
    sys.stdout.write(json.dumps({{"jsonrpc": "2.0", "method": method, "params": params}}) + "\n")
    sys.stdout.flush()

state = {{}}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params") or {{}}
    request_id = request.get("id")
    if method == "initialize":
        reply(request_id, {{"userAgent": "stub"}})
        continue
    if method == "initialized":
        continue
{script}
"#,
        script = script
            .lines()
            .map(|line| format!("    {line}"))
            .collect::<Vec<_>>()
            .join("\n"),
    );
    std::fs::write(path, stub).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

#[tokio::test]
async fn sending_to_an_existing_thread_resumes_it_before_starting_a_turn() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    // The real app-server answers `turn/start` with "thread not found" until
    // the thread has been resumed in this same process, so a send that does
    // not resume first can never reach the model.
    write_app_server_stub(
        &stub,
        r#"if method == "thread/resume":
    state[params["threadId"]] = True
    reply(request_id, {"thread": {"id": params["threadId"]}})
    continue
if method == "turn/start":
    if not state.get(params["threadId"]):
        fail(request_id, "thread not found: " + params["threadId"])
        continue
    reply(request_id, {"turn": {"id": "turn-1"}})
    continue
if request_id is not None:
    fail(request_id, "unexpected method " + str(method))
"#,
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    adapter
        .send("thread-1", "fixed probe".into(), Vec::new())
        .await
        .expect("a send to an existing thread must resume it instead of failing");
}

#[tokio::test]
async fn a_thread_is_resumed_once_across_repeated_sends() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    let resumes = root.path().join("resumes.txt");
    write_app_server_stub(
        &stub,
        &format!(
            r#"if method == "thread/resume":
    state[params["threadId"]] = True
    with open({path:?}, "a") as handle:
        handle.write(params["threadId"] + "\n")
    reply(request_id, {{"thread": {{"id": params["threadId"]}}}})
    continue
if method == "turn/start":
    if not state.get(params["threadId"]):
        fail(request_id, "thread not found")
        continue
    reply(request_id, {{"turn": {{"id": "turn-1"}}}})
    notify("turn/completed", {{"threadId": params["threadId"], "turn": {{"status": "completed"}}}})
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
            path = resumes.to_str().unwrap(),
        ),
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    adapter
        .send("thread-1", "first".into(), Vec::new())
        .await
        .unwrap();
    // Wait for the completion notification so the turn lease is released.
    for _ in 0..50 {
        if adapter.write_availability("thread-1").await.unwrap()
            == remote_ai_agent::protocol::WriteState::Available
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    adapter
        .send("thread-1", "second".into(), Vec::new())
        .await
        .unwrap();

    let recorded = std::fs::read_to_string(&resumes).unwrap_or_default();
    assert_eq!(
        recorded.lines().count(),
        1,
        "a thread already loaded in this process must not be resumed again: {recorded:?}"
    );
}

#[test]
fn a_failed_codex_turn_is_reported_as_a_failure_with_the_provider_message() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let event = mapper
        .map_notification(
            r#"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"turn-1","status":"failed","error":{"message":"You've hit your usage limit."}}}}"#,
        )
        .unwrap();
    match event {
        ConversationEvent::TurnFailed(payload) => {
            assert_eq!(payload["message"], "You've hit your usage limit.");
            assert_eq!(payload["conversationId"], "t1");
        }
        other => panic!("a failed turn must not be reported as completed: {other:?}"),
    }
}

#[test]
fn a_codex_error_notification_reaches_the_phone_as_a_turn_failure() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let event = mapper
        .map_notification(
            r#"{"method":"error","params":{"threadId":"t1","error":{"message":"upstream refused"}}}"#,
        )
        .unwrap();
    match event {
        ConversationEvent::TurnFailed(payload) => {
            assert_eq!(payload["message"], "upstream refused");
        }
        other => panic!("a provider error must surface as a failure: {other:?}"),
    }
}

#[tokio::test]
async fn codex_chats_come_from_the_local_thread_catalog_without_a_host_bridge() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    write_app_server_stub(
        &stub,
        r#"if method == "thread/list":
    reply(request_id, {"data": [
        {"id": "chat-1", "name": "A chat", "cwd": "/tmp/anywhere", "updatedAt": 20},
    ], "nextCursor": None})
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    let chats = adapter.list_daily_conversations().await.unwrap();

    assert_eq!(
        chats
            .iter()
            .map(|chat| chat.id.as_str())
            .collect::<Vec<_>>(),
        ["chat-1"],
        "Codex Chats must list the provider's own threads, not an empty catalog"
    );
    assert!(
        chats
            .iter()
            .all(|chat| chat.kind == ConversationKind::Daily && chat.project_id.is_none())
    );
    assert_eq!(adapter.daily_catalog_diagnostic_code(), None);
}

#[tokio::test]
async fn codex_project_conversations_follow_every_thread_list_page() {
    use remote_ai_agent::adapters::ProviderAdapter;
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

    let root = tempfile::tempdir().unwrap();
    let project_dir = root.path().join("project");
    std::fs::create_dir_all(&project_dir).unwrap();
    let codex_dir = root.path().join(".codex");
    std::fs::create_dir_all(&codex_dir).unwrap();
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(codex_dir.join("state_5.sqlite"))
                .create_if_missing(true),
        )
        .await
        .unwrap();
    sqlx::query(
        "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, position INTEGER NOT NULL)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO projects VALUES ('p1','project',2000,0)")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(&format!(
        "INSERT INTO project_roots VALUES ('p1',0,'{}')",
        project_dir.canonicalize().unwrap().display()
    ))
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;

    let stub = root.path().join("stub-app-server.py");
    // The project's only thread sits on the second page. A single-page read
    // reports the project as having no sessions at all.
    write_app_server_stub(
        &stub,
        &format!(
            r#"if method == "thread/list":
    if params.get("cursor") is None:
        reply(request_id, {{"data": [
            {{"id": "other", "name": "Elsewhere", "cwd": "/tmp/elsewhere", "updatedAt": 30}},
        ], "nextCursor": "page-2"}})
    else:
        reply(request_id, {{"data": [
            {{"id": "wanted", "name": "In project", "cwd": {path:?}, "updatedAt": 20}},
        ], "nextCursor": None}})
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
            path = project_dir.canonicalize().unwrap().to_str().unwrap(),
        ),
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    let conversations = adapter.list_project_conversations("p1").await.unwrap();

    assert_eq!(
        conversations
            .iter()
            .map(|conversation| conversation.id.as_str())
            .collect::<Vec<_>>(),
        ["wanted"],
        "a project session must stay reachable when it is not on the first page"
    );
}

#[tokio::test]
async fn a_new_chat_runs_in_the_paired_home_not_the_agent_directory() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    let recorded = root.path().join("start-cwd.txt");
    write_app_server_stub(
        &stub,
        &format!(
            r#"if method == "thread/start":
    with open({path:?}, "w") as handle:
        handle.write(str(params.get("cwd")))
    reply(request_id, {{"thread": {{"id": "chat-new"}}}})
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
            path = recorded.to_str().unwrap(),
        ),
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    let id = adapter.start(ConversationKind::Daily, None).await.unwrap();

    assert_eq!(id, "chat-new");
    assert_eq!(
        std::fs::read_to_string(&recorded).unwrap(),
        root.path().to_str().unwrap(),
        "a chat is not bound to a project, so it runs in the paired user's HOME"
    );
}

#[tokio::test]
async fn a_chat_started_here_can_be_written_without_resuming_it_again() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    write_app_server_stub(
        &stub,
        r#"if method == "thread/start":
    state["chat-new"] = True
    reply(request_id, {"thread": {"id": "chat-new"}})
    continue
if method == "thread/resume":
    fail(request_id, "a thread started in this process must not be resumed")
    continue
if method == "turn/start":
    if not state.get(params["threadId"]):
        fail(request_id, "thread not found")
        continue
    reply(request_id, {"turn": {"id": "turn-1"}})
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    let id = adapter.start(ConversationKind::Daily, None).await.unwrap();
    adapter
        .send(&id, "fixed probe".into(), Vec::new())
        .await
        .expect("the first send after a start must not need a resume");
}

#[tokio::test]
async fn a_thread_with_no_first_message_yet_has_an_empty_history_not_an_error() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    // Verbatim from codex-cli 0.144.4: a thread that exists but has not
    // received a user message yet refuses `includeTurns`. The phone opens the
    // transcript before the first turn exists, so this is an empty history.
    write_app_server_stub(
        &stub,
        r#"if method == "thread/read":
    fail(
        request_id,
        "thread " + params["threadId"]
        + " is not materialized yet; includeTurns is unavailable before first user message",
    )
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    let page = adapter
        .load_conversation("brand-new-thread", None)
        .await
        .expect("an unmaterialized thread must read as an empty history");

    assert_eq!(page.conversation_id, "brand-new-thread");
    assert!(page.events.is_empty());
    assert_eq!(page.next_cursor, None);
}

#[tokio::test]
async fn a_real_thread_read_failure_is_still_reported() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    write_app_server_stub(
        &stub,
        r#"if method == "thread/read":
    fail(request_id, "thread not found: " + params["threadId"])
    continue
if request_id is not None:
    fail(request_id, "unexpected method")
"#,
    );

    let adapter = CodexAdapter::new(&stub, root.path());
    adapter
        .load_conversation("missing-thread", None)
        .await
        .expect_err("a genuine read failure must not be hidden as empty history");
}

#[tokio::test]
async fn a_dead_app_server_is_replaced_on_the_next_write() {
    use remote_ai_agent::adapters::ProviderAdapter;

    let root = tempfile::tempdir().unwrap();
    let stub = root.path().join("stub-app-server.py");
    let runs = root.path().join("runs.txt");
    // The first process answers `initialize` and then exits, the way a crashed
    // or killed CLI does. A cached handle to it can never carry another turn,
    // so the adapter has to notice and start a new one.
    std::fs::write(
        &stub,
        format!(
            r#"#!/usr/bin/env python3
import json, os, sys

runs_path = {path:?}
with open(runs_path, "a") as handle:
    handle.write("run\n")
with open(runs_path) as handle:
    run = len(handle.readlines())

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        sys.stdout.write(
            json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": {{"userAgent": "stub"}}}}) + "\n"
        )
        sys.stdout.flush()
        if run == 1:
            os._exit(1)
        continue
    if method == "initialized":
        continue
    if method == "thread/resume":
        sys.stdout.write(
            json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": {{"thread": {{"id": request["params"]["threadId"]}}}}}}) + "\n"
        )
        sys.stdout.flush()
        continue
    if method == "turn/start":
        sys.stdout.write(
            json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": {{"turn": {{"id": "turn-1"}}}}}}) + "\n"
        )
        sys.stdout.flush()
        continue
"#,
            path = runs.to_str().unwrap(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();

    let adapter = CodexAdapter::new(&stub, root.path());
    // The first write lands on the process that exits. It is allowed to fail.
    let _ = adapter.send("thread-1", "first".into(), Vec::new()).await;
    adapter.write_availability("thread-1").await.unwrap();

    adapter
        .send("thread-1", "second".into(), Vec::new())
        .await
        .expect("a write after the CLI died must start a new app-server");
    assert!(
        std::fs::read_to_string(&runs).unwrap().lines().count() >= 2,
        "the adapter kept using the dead process instead of replacing it"
    );
}

#[test]
fn an_unnamed_thread_is_titled_from_what_it_does_carry() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let conversations = mapper
        .map_thread_list(
            r#"{"data":[
                {"id":"named","name":"Chosen name","preview":"ignored","cwd":"/Users/test"},
                {"id":"preview-only","name":null,"preview":"  fix the\n  login flow  ","cwd":"/Users/test"},
                {"id":"nothing","name":null,"preview":"","cwd":"/Users/test"}
            ]}"#,
        )
        .unwrap();
    let titles = conversations
        .iter()
        .map(|conversation| conversation.title.as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        titles,
        ["Chosen name", "fix the login flow", "Untitled Codex thread"]
    );
}

#[test]
fn a_pasted_prompt_does_not_become_the_whole_list_row() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test"));
    let long = "word ".repeat(200);
    let line = serde_json::json!({
        "data": [{"id": "long", "name": null, "preview": long, "cwd": "/Users/test"}]
    })
    .to_string();
    let conversations = mapper.map_thread_list(&line).unwrap();
    assert!(conversations[0].title.chars().count() <= 81);
    assert!(conversations[0].title.ends_with('…'));
}

/// A `thread/read` response with `turns` complete exchanges.
fn codex_thread_read(turns: usize) -> String {
    let turns = (1..=turns)
        .map(|turn| {
            serde_json::json!({
                "id": format!("turn-{turn}"),
                "items": [
                    {"type": "userMessage", "id": format!("user-{turn}"), "text": format!("ask {turn}")},
                    {"type": "commandExecution", "id": format!("tool-{turn}"), "command": "ls"},
                    {"type": "agentMessage", "id": format!("assistant-{turn}"), "text": format!("answer {turn}")},
                ]
            })
        })
        .collect::<Vec<_>>();
    serde_json::json!({"result": {"thread": {"id": "paged", "turns": turns}}}).to_string()
}

fn codex_user_texts(events: &[serde_json::Value]) -> Vec<String> {
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

#[test]
fn codex_history_opens_on_the_newest_turns_and_pages_backwards() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test")).with_history_turns(3);
    let response = codex_thread_read(7);

    let first = mapper.map_thread_read(&response, "paged", None).unwrap();
    assert_eq!(
        codex_user_texts(&first.events),
        ["ask 5", "ask 6", "ask 7"],
        "the transcript opens on the newest turns, still oldest-first inside \
         the page: {:?}",
        first.events
    );

    let second = mapper
        .map_thread_read(&response, "paged", first.next_cursor.clone())
        .unwrap();
    assert_eq!(
        codex_user_texts(&second.events),
        ["ask 2", "ask 3", "ask 4"]
    );

    let third = mapper
        .map_thread_read(&response, "paged", second.next_cursor.clone())
        .unwrap();
    assert_eq!(codex_user_texts(&third.events), ["ask 1"]);
    assert_eq!(third.next_cursor, None, "the oldest page ends the walk");
}

#[test]
fn a_codex_turn_is_never_split_across_history_pages() {
    let mapper = CodexMapper::new(PathBuf::from("/Users/test")).with_history_turns(2);
    let response = codex_thread_read(5);

    let mut cursor = None;
    let mut pages = 0;
    loop {
        let page = mapper.map_thread_read(&response, "paged", cursor).unwrap();
        pages += 1;
        assert_eq!(
            page.events.first().map(|event| &event["type"]),
            Some(&serde_json::json!("conversation.user_message")),
            "a page starts at a turn boundary: {:?}",
            page.events
        );
        assert_eq!(
            page.events.len(),
            codex_user_texts(&page.events).len() * 3,
            "each turn in the page carries its whole exchange: {:?}",
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

#[test]
fn a_codex_history_item_keeps_its_id_whichever_page_it_lands_on() {
    // Synthetic ids are derived from the turn's position in the whole thread,
    // so an item must not be renumbered just because it arrived on a later
    // page. The phone dedupes history by id.
    let response = serde_json::json!({"result": {"thread": {"id": "paged", "turns": [
        {"items": [{"type": "userMessage", "text": "ask 1"}]},
        {"items": [{"type": "userMessage", "text": "ask 2"}]},
    ]}}})
    .to_string();

    let whole = CodexMapper::new(PathBuf::from("/Users/test"))
        .with_history_turns(5)
        .map_thread_read(&response, "paged", None)
        .unwrap();
    let paged = CodexMapper::new(PathBuf::from("/Users/test")).with_history_turns(1);
    let newest = paged.map_thread_read(&response, "paged", None).unwrap();
    let older = paged
        .map_thread_read(&response, "paged", newest.next_cursor.clone())
        .unwrap();

    let ids = |events: &[serde_json::Value]| {
        events
            .iter()
            .map(|event| {
                event["payload"]["messageId"]
                    .as_str()
                    .unwrap_or("")
                    .to_owned()
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(
        [ids(&older.events), ids(&newest.events)].concat(),
        ids(&whole.events),
        "an item's id must not depend on which page delivered it"
    );
}
