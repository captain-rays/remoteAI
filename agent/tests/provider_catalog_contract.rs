use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use remote_ai_agent::adapters::codex::{CodexAdapter, CodexHostBridge};
use remote_ai_agent::adapters::{ConversationPage, ProviderAdapter};
use remote_ai_agent::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProjectSummary,
    ProviderId, ProviderStatus,
};
use serde_json::Value;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

fn summary(
    id: &str,
    title: &str,
    kind: ConversationKind,
    path: Option<&str>,
) -> ConversationSummary {
    ConversationSummary {
        id: id.into(),
        provider: ProviderId::Codex,
        kind,
        title: title.into(),
        project_id: None,
        project_path: path.map(str::to_owned),
        updated_at: Utc.timestamp_opt(10, 0).single().unwrap(),
        status: "idle".into(),
        write_state: None,
        write_block_code: None,
        source: None,
        working_path: None,
    }
}

struct FixtureCodexHostBridge {
    chats: Vec<ConversationSummary>,
    calls: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl CodexHostBridge for FixtureCodexHostBridge {
    async fn list_chatgpt_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        Ok(self.chats.clone())
    }

    async fn load_chatgpt_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("load:{id}:{}", cursor.unwrap_or_default()));
        Ok(ConversationPage {
            conversation_id: id.into(),
            events: vec![serde_json::json!({
                "type": "conversation.message_completed",
                "payload": {"text": "host history"}
            })],
            next_cursor: None,
        })
    }

    async fn resume_chatgpt_conversation(&self, id: &str) -> anyhow::Result<()> {
        self.calls.lock().unwrap().push(format!("resume:{id}"));
        Ok(())
    }

    async fn send_chatgpt_message(
        &self,
        id: &str,
        text: String,
        _attachments: Vec<PathBuf>,
    ) -> anyhow::Result<()> {
        self.calls.lock().unwrap().push(format!("send:{id}:{text}"));
        Ok(())
    }

    async fn start_chatgpt_conversation(&self, _cwd: Option<PathBuf>) -> anyhow::Result<String> {
        self.calls.lock().unwrap().push("start".into());
        Ok("host-new-chat".into())
    }
}

#[tokio::test]
async fn codex_chats_never_come_from_the_recent_session_index() {
    let temp = tempfile::tempdir().unwrap();
    let codex_dir = temp.path().join(".codex");
    std::fs::create_dir_all(&codex_dir).unwrap();
    std::fs::write(
        codex_dir.join("session_index.jsonl"),
        r#"{"id":"wrong-project-task","thread_name":"must not leak"}"#,
    )
    .unwrap();

    // Stand in for the app-server with an empty thread list. The recent-session
    // index is a local convenience file, not the provider's conversation
    // catalog, so nothing in it may appear in Chats.
    let stub = temp.path().join("stub-app-server.py");
    std::fs::write(
        &stub,
        r#"#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    if request.get("id") is None:
        continue
    result = {"data": [], "nextCursor": None}
    if request.get("method") == "initialize":
        result = {"userAgent": "stub"}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()
"#,
    )
    .unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();

    let adapter = CodexAdapter::new(&stub, temp.path());
    let chats = adapter.list_daily_conversations().await.unwrap();

    assert!(
        chats.is_empty(),
        "recent-index entries must not become Chats"
    );
    // The Chats view now has a local source, so an empty list is a real empty
    // catalog rather than a missing bridge.
    assert_eq!(adapter.daily_catalog_diagnostic_code(), None);
    assert_eq!(adapter.status().await.reason, None);
}

#[tokio::test]
async fn codex_chats_accept_only_host_chatgpt_rows_and_clear_project_identity() {
    let adapter = CodexAdapter::new("codex", "/Users/test").with_host_bridge(Arc::new(
        FixtureCodexHostBridge {
            chats: vec![
                summary("chat", "Chat", ConversationKind::Daily, None),
                summary(
                    "wrong",
                    "Wrong project task",
                    ConversationKind::Project,
                    Some("/tmp"),
                ),
            ],
            calls: Arc::new(Mutex::new(Vec::new())),
        },
    ));

    let chats = adapter.list_daily_conversations().await.unwrap();

    assert_eq!(
        chats
            .iter()
            .map(|chat| chat.id.as_str())
            .collect::<Vec<_>>(),
        ["chat"]
    );
    assert!(chats.iter().all(|chat| {
        chat.provider == ProviderId::Codex
            && chat.kind == ConversationKind::Daily
            && chat.project_id.is_none()
            && chat.project_path.is_none()
    }));
    assert_eq!(adapter.daily_catalog_diagnostic_code(), None);
}

#[tokio::test]
async fn codex_host_chat_ids_route_history_resume_send_and_daily_start_through_bridge() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let bridge = Arc::new(FixtureCodexHostBridge {
        chats: vec![summary(
            "host-chat",
            "Host Chat",
            ConversationKind::Daily,
            None,
        )],
        calls: calls.clone(),
    });
    let adapter =
        CodexAdapter::new("/definitely/missing/codex", "/Users/test").with_host_bridge(bridge);

    let page = adapter
        .load_conversation("host-chat", Some("cursor-1".into()))
        .await
        .unwrap();
    adapter.resume("host-chat").await.unwrap();
    adapter
        .send("host-chat", "hello from host".into(), Vec::new())
        .await
        .unwrap();
    let new_id = adapter.start(ConversationKind::Daily, None).await.unwrap();

    assert_eq!(page.events[0]["payload"]["text"], "host history");
    assert_eq!(new_id, "host-new-chat");
    assert_eq!(
        *calls.lock().unwrap(),
        vec![
            "load:host-chat:cursor-1",
            "resume:host-chat",
            "send:host-chat:hello from host",
            "start",
        ]
    );
}

async fn make_codex_state_db(root: &std::path::Path) {
    let codex_dir = root.join(".codex");
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
    sqlx::query(
        "INSERT INTO projects VALUES
         ('project-a','Project A',3000,0),
         ('project-b','Project B',2000,1),
         ('project-c','Project C',1000,2)",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO project_roots VALUES
         ('project-a',1,'/tmp/not-primary'),
         ('project-a',0,'/tmp/shared'),
         ('project-b',0,'/tmp/shared'),
         ('project-c',0,'/tmp/secondary')",
    )
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;
}

#[tokio::test]
async fn codex_projects_keep_same_paths_separate_and_select_one_primary_root() {
    let temp = tempfile::tempdir().unwrap();
    make_codex_state_db(temp.path()).await;
    let adapter = CodexAdapter::new("codex", temp.path());

    let projects = adapter.list_projects().await.unwrap();

    assert_eq!(projects.len(), 3);
    assert_eq!(
        projects
            .iter()
            .map(|project| project.id.as_str())
            .collect::<Vec<_>>(),
        ["project-a", "project-b", "project-c"]
    );
    assert_eq!(projects[0].canonical_path, "/tmp/shared");
    assert_eq!(projects[1].canonical_path, "/tmp/shared");
    assert_eq!(projects[2].canonical_path, "/tmp/secondary");
}

fn write_claude_desktop_fixture(root: &std::path::Path) {
    let metadata_root = root.join("Library/Application Support/Claude/claude-code-sessions");
    std::fs::create_dir_all(&metadata_root).unwrap();
    let fixtures = [
        (
            "local_01_project.json",
            include_str!("fixtures/claude/desktop/catalog/local_01_project.json"),
        ),
        (
            "local_02_beem_agent.json",
            include_str!("fixtures/claude/desktop/catalog/local_02_beem_agent.json"),
        ),
        (
            "local_03_beem_ai.json",
            include_str!("fixtures/claude/desktop/catalog/local_03_beem_ai.json"),
        ),
        (
            "local_04_new_agent.json",
            include_str!("fixtures/claude/desktop/catalog/local_04_new_agent.json"),
        ),
        (
            "local_05_pi_agent.json",
            include_str!("fixtures/claude/desktop/catalog/local_05_pi_agent.json"),
        ),
        (
            "local_06_remote.json",
            include_str!("fixtures/claude/desktop/catalog/local_06_remote.json"),
        ),
        (
            "local_archived.json",
            include_str!("fixtures/claude/desktop/catalog/local_archived.json"),
        ),
    ];
    for (name, content) in fixtures {
        std::fs::write(
            metadata_root.join(name),
            content.replace("/Users/test", root.to_str().unwrap()),
        )
        .unwrap();
    }
}

#[tokio::test]
async fn claude_reads_both_desktop_surfaces_and_excludes_archived() {
    let temp = tempfile::tempdir().unwrap();
    write_claude_desktop_fixture(temp.path());
    std::fs::create_dir_all(temp.path().join("药盒")).unwrap();
    let legacy_root = temp
        .path()
        .join("Library/Application Support/Claude/local-agent-mode-sessions");
    std::fs::create_dir_all(&legacy_root).unwrap();
    std::fs::write(
        legacy_root.join("local_legacy.json"),
        include_str!("fixtures/claude/desktop/catalog/local_legacy.json"),
    )
    .unwrap();

    let adapter = remote_ai_agent::adapters::claude::ClaudeAdapter::new("claude", temp.path());
    let chats = adapter.list_daily_conversations().await.unwrap();
    let projects = adapter.list_projects().await.unwrap();

    // "Chats and tasks" is its own store. A Code-tab session is reached
    // through its project, and must not crowd the chat list.
    assert!(
        chats.iter().any(|chat| chat.id == "legacy"),
        "the desktop chat store belongs in Chats: {:?}",
        chats.iter().map(|chat| &chat.id).collect::<Vec<_>>()
    );
    assert!(
        !chats.iter().any(|chat| chat.id.starts_with("desktop-")),
        "a Code-tab session is not a chat: {:?}",
        chats.iter().map(|chat| &chat.id).collect::<Vec<_>>()
    );
    assert_eq!(projects.len(), 6);
    assert!(
        !projects
            .iter()
            .any(|project| project.canonical_path.contains("legacy")),
        "a chat's own directory is not a project"
    );
    assert!(!chats.iter().any(|chat| chat.id == "archived"));
    assert!(
        chats
            .iter()
            .all(|chat| chat.kind == ConversationKind::Daily)
    );
    assert!(
        projects
            .iter()
            .all(|project| project.provider == ProviderId::Claude)
    );
    let mut titles = projects
        .iter()
        .map(|project| project.title.as_str())
        .collect::<Vec<_>>();
    titles.sort_unstable();
    assert_eq!(
        titles,
        [
            "beem-agent-data-server",
            "beem-ai-data-server",
            "new-agent",
            "pi-agent",
            "remoteAICli",
            "药盒",
        ]
    );
}

#[tokio::test]
async fn claude_falls_back_to_legacy_desktop_root_when_new_root_is_absent() {
    let temp = tempfile::tempdir().unwrap();
    let legacy_root = temp
        .path()
        .join("Library/Application Support/Claude/local-agent-mode-sessions");
    std::fs::create_dir_all(&legacy_root).unwrap();
    std::fs::write(
        legacy_root.join("local_legacy.json"),
        include_str!("fixtures/claude/desktop/catalog/local_legacy.json")
            .replace("/Users/test", temp.path().to_str().unwrap()),
    )
    .unwrap();

    let adapter = remote_ai_agent::adapters::claude::ClaudeAdapter::new("claude", temp.path());
    let chats = adapter.list_daily_conversations().await.unwrap();

    assert_eq!(chats.len(), 1);
    assert_eq!(chats[0].id, "legacy");
}

#[tokio::test]
async fn claude_code_session_is_in_its_project_view_and_uses_cli_session_id() {
    let temp = tempfile::tempdir().unwrap();
    write_claude_desktop_fixture(temp.path());
    std::fs::create_dir_all(temp.path().join("药盒")).unwrap();
    let transcript_root = temp.path().join(".claude/projects/project");
    std::fs::create_dir_all(&transcript_root).unwrap();
    std::fs::write(
        transcript_root.join("cli-01.jsonl"),
        include_str!("fixtures/claude/projects/desktop-cli-01.jsonl")
            .replace("/Users/test", temp.path().to_str().unwrap()),
    )
    .unwrap();
    let stub = temp.path().join("fake-claude.sh");
    std::fs::write(
        &stub,
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$PWD/claude-args.txt\"\ncat >/dev/null\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let adapter = remote_ai_agent::adapters::claude::ClaudeAdapter::new(&stub, temp.path());

    let chats = adapter.list_daily_conversations().await.unwrap();
    let project = adapter
        .list_projects()
        .await
        .unwrap()
        .into_iter()
        .find(|project| project.title == "药盒")
        .unwrap();
    let project_chats = adapter
        .list_project_conversations(&project.id)
        .await
        .unwrap();
    assert!(
        !chats.iter().any(|chat| chat.id == "desktop-01"),
        "a Code-tab session is reached through its project, not through Chats"
    );

    assert_eq!(project_chats.len(), 1);
    assert_eq!(project_chats[0].id, "desktop-01");
    assert_eq!(project_chats[0].kind, ConversationKind::Project);
    assert_eq!(
        project_chats[0].project_id.as_deref(),
        Some(project.id.as_str())
    );
    let history = adapter.load_conversation("desktop-01", None).await.unwrap();
    assert_eq!(
        history.events[0]["payload"]["text"],
        "history through cli id"
    );

    adapter.resume("desktop-01").await.unwrap();
    adapter
        .send("desktop-01", "send through cli id".into(), Vec::new())
        .await
        .unwrap();
    let args_path = temp.path().join("药盒/claude-args.txt");
    let args = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            if let Ok(args) = std::fs::read_to_string(&args_path) {
                let has_resume = args
                    .lines()
                    .collect::<Vec<_>>()
                    .windows(2)
                    .any(|pair| pair == ["--resume", "cli-01"]);
                if has_resume {
                    break args;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("Claude resume should invoke the CLI in the selected project");
    assert!(
        args.lines()
            .collect::<Vec<_>>()
            .windows(2)
            .any(|pair| pair == ["--resume", "cli-01"])
    );
}

#[tokio::test]
async fn claude_project_view_uses_the_selected_folder_that_matched_the_project() {
    let temp = tempfile::tempdir().unwrap();
    let metadata_root = temp
        .path()
        .join("Library/Application Support/Claude/claude-code-sessions");
    std::fs::create_dir_all(&metadata_root).unwrap();
    let content = format!(
        r#"{{"sessionId":"desktop-selected","cliSessionId":"cli-selected","title":"Selected folder","cwd":"{}/workspace","createdAt":1725400000000,"lastActivityAt":1725400060000,"isArchived":false,"userSelectedFolders":["{}/药盒"]}}"#,
        temp.path().display(),
        temp.path().display(),
    );
    std::fs::write(metadata_root.join("local_selected.json"), content).unwrap();

    let adapter = remote_ai_agent::adapters::claude::ClaudeAdapter::new("claude", temp.path());
    let project = adapter
        .list_projects()
        .await
        .unwrap()
        .into_iter()
        .find(|project| project.title == "药盒")
        .unwrap();
    let conversations = adapter
        .list_project_conversations(&project.id)
        .await
        .unwrap();

    assert_eq!(conversations.len(), 1);
    assert_eq!(
        conversations[0].project_path.as_deref(),
        Some(project.canonical_path.as_str())
    );
}

#[test]
fn fixture_metadata_contains_only_the_desktop_allowlist() {
    let raw: Value = serde_json::from_str(include_str!(
        "fixtures/claude/desktop/catalog/local_01_project.json"
    ))
    .unwrap();
    let mut keys = raw.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    keys.sort_unstable();
    assert_eq!(
        keys,
        vec![
            "cliSessionId",
            "createdAt",
            "cwd",
            "isArchived",
            "lastActivityAt",
            "sessionId",
            "title",
            "userSelectedFolders"
        ]
    );
}

// Keep the imports in the fixture contract explicit: this test module is the
// boundary for the adapter API and must not grow a credential-bearing helper.
#[allow(dead_code)]
fn _adapter_api_types(
    _event: ConversationEvent,
    _decision: ApprovalDecision,
    _status: ProviderStatus,
    _project: ProjectSummary,
) {
}
