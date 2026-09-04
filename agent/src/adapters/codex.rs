use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader as StdBufReader, Write as StdWrite};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Value, json};
use sqlx::Row;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, RwLock, broadcast, oneshot};

static INDEX_TEMP_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Upper bound on `thread/list` pages read in one catalog refresh. The list is
/// newest-first, so this bounds the cost of a read while still reaching far
/// enough back to cover every project that has recent work.
const MAX_THREAD_LIST_PAGES: usize = 20;

use super::{ConversationPage, ProviderAdapter};
use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProjectSummary,
    ProviderId, ProviderStatus, WriteState,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

/// Bridge owned by the desktop host. Codex's personal ChatGPT history is
/// available to the unified host list, not to an independent Rust process.
/// The agent therefore accepts an explicit bridge instead of guessing from
/// local project/session files.
#[async_trait]
pub trait CodexHostBridge: Send + Sync {
    async fn list_chatgpt_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>>;
    async fn load_chatgpt_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage>;
    async fn resume_chatgpt_conversation(&self, id: &str) -> anyhow::Result<()>;
    async fn send_chatgpt_message(
        &self,
        id: &str,
        text: String,
        attachments: Vec<PathBuf>,
    ) -> anyhow::Result<()>;
    async fn start_chatgpt_conversation(&self, cwd: Option<PathBuf>) -> anyhow::Result<String>;
}

#[derive(Debug, Clone)]
pub struct CodexMapper {
    home: PathBuf,
}

impl CodexMapper {
    pub fn new(home: PathBuf) -> Self {
        Self { home }
    }

    pub fn map_thread_list(&self, line: &str) -> anyhow::Result<Vec<ConversationSummary>> {
        let value: Value = serde_json::from_str(line)?;
        self.map_thread_list_value(value.get("result").unwrap_or(&value))
    }

    /// Normalize one entry from Codex's local `session_index.jsonl`.  These
    /// entries back the CLI's global "Recent" list and intentionally contain
    /// only metadata (never transcript contents).
    pub fn map_session_index_line(&self, line: &str) -> anyhow::Result<ConversationSummary> {
        let value: Value = serde_json::from_str(line)?;
        let id = required_string(&value, "id")?;
        Ok(ConversationSummary {
            id,
            provider: ProviderId::Codex,
            kind: ConversationKind::Daily,
            title: value
                .get("thread_name")
                .and_then(Value::as_str)
                .filter(|title| !title.trim().is_empty())
                .unwrap_or("Untitled Codex conversation")
                .to_owned(),
            project_id: None,
            project_path: None,
            updated_at: parse_time(value.get("updated_at")),
            status: "idle".to_owned(),
            write_state: None,
            write_block_code: None,
        })
    }

    /// Parse bounded JSONL metadata from the Codex recent-session index.
    /// Malformed or oversized records are ignored so one damaged line cannot
    /// hide the remaining recent conversations.
    pub fn map_session_index(&self, content: &str) -> Vec<ConversationSummary> {
        const MAX_INDEX_ENTRIES: usize = 4096;
        const MAX_LINE_BYTES: usize = 64 * 1024;
        let mut summaries = content
            .lines()
            .take(MAX_INDEX_ENTRIES)
            .filter(|line| line.len() <= MAX_LINE_BYTES)
            .filter_map(|line| self.map_session_index_line(line).ok())
            .collect::<Vec<_>>();
        summaries.sort_by_key(|summary| Reverse(summary.updated_at));
        summaries
    }

    /// Upsert only the metadata Codex uses for its global recent list.  The
    /// index deliberately contains no message text or prompt data.
    pub fn upsert_session_index_content(
        content: &str,
        id: &str,
        updated_at: DateTime<Utc>,
    ) -> String {
        if id.trim().is_empty() {
            return content.to_owned();
        }
        let mut records = Vec::new();
        let mut seen = HashSet::new();
        let updated_at = updated_at.to_rfc3339();
        for line in content
            .lines()
            .take(4096)
            .filter(|line| line.len() <= 64 * 1024)
        {
            let Ok(mut record) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let Some(record_id) = record.get("id").and_then(Value::as_str) else {
                continue;
            };
            if !seen.insert(record_id.to_owned()) {
                continue;
            }
            if record_id == id {
                record["updated_at"] = Value::String(updated_at.clone());
                if record
                    .get("thread_name")
                    .and_then(Value::as_str)
                    .is_none_or(|title| title.trim().is_empty())
                {
                    record["thread_name"] = Value::String("New Codex conversation".to_owned());
                }
            }
            records.push(record);
        }
        if seen.insert(id.to_owned()) {
            records.push(json!({
                "id": id,
                "thread_name": "New Codex conversation",
                "updated_at": updated_at,
            }));
        }
        records
            .into_iter()
            .filter_map(|record| serde_json::to_string(&record).ok())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Atomically update the local recent-session index with metadata only.
    pub fn write_session_index_entry(
        &self,
        id: &str,
        updated_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        let path = self.home.join(".codex/session_index.jsonl");
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Codex home has no parent"))?;
        fs::create_dir_all(parent)?;
        let content = fs::read_to_string(&path).unwrap_or_default();
        let replacement = Self::upsert_session_index_content(&content, id, updated_at);
        let temp_path = parent.join(format!(
            ".session_index.jsonl.{}.{}",
            std::process::id(),
            INDEX_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let write_result = (|| -> anyhow::Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temp_path)?;
            file.write_all(replacement.as_bytes())?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o600))?;
            fs::rename(&temp_path, &path)?;
            Ok(())
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        write_result
    }

    /// Normalize a Codex `thread/read` response into the provider-neutral
    /// history representation.  The cursor is an opaque item offset; only
    /// bounded, allow-listed fields are copied into the response.
    pub fn map_thread_read(
        &self,
        line: &str,
        conversation_id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        let value: Value = serde_json::from_str(line)?;
        self.map_thread_read_value(&value, conversation_id, cursor)
    }

    fn map_thread_read_value(
        &self,
        value: &Value,
        conversation_id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        let thread = value
            .pointer("/result/thread")
            .or_else(|| value.pointer("/thread"))
            .ok_or_else(|| anyhow::anyhow!("thread/read response has no thread"))?;
        let actual_id = thread.get("id").and_then(Value::as_str).unwrap_or_default();
        anyhow::ensure!(
            actual_id.is_empty() || actual_id == conversation_id,
            "thread ID mismatch"
        );
        let mut normalized = Vec::new();
        if let Some(turns) = thread.get("turns").and_then(Value::as_array) {
            for (turn_index, turn) in turns.iter().enumerate() {
                if let Some(items) = turn.get("items").and_then(Value::as_array) {
                    for (item_index, item) in items.iter().enumerate() {
                        normalized.extend(normalize_codex_item(
                            conversation_id,
                            turn_index,
                            item_index,
                            item,
                        ));
                    }
                }
            }
        }
        let start = cursor
            .as_deref()
            .map(|raw| raw.parse::<usize>())
            .transpose()
            .map_err(|_| anyhow::anyhow!("invalid history cursor"))?
            .unwrap_or(0);
        anyhow::ensure!(start <= normalized.len(), "history cursor out of range");
        const PAGE_SIZE: usize = 6;
        let end = (start + PAGE_SIZE).min(normalized.len());
        Ok(ConversationPage {
            conversation_id: conversation_id.to_owned(),
            events: normalized[start..end].to_vec(),
            next_cursor: (end < normalized.len()).then(|| end.to_string()),
        })
    }

    fn map_thread_list_value(&self, result: &Value) -> anyhow::Result<Vec<ConversationSummary>> {
        result
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow::anyhow!("thread/list response has no data"))?
            .iter()
            .map(|thread| self.map_thread(thread))
            .collect()
    }

    fn map_thread(&self, thread: &Value) -> anyhow::Result<ConversationSummary> {
        let id = required_string(thread, "id")?;
        let cwd = thread.get("cwd").and_then(Value::as_str).map(PathBuf::from);
        let kind = if cwd
            .as_deref()
            .is_none_or(|path| same_path(path, &self.home))
        {
            ConversationKind::Daily
        } else {
            ConversationKind::Project
        };
        let project_path = (kind == ConversationKind::Project)
            .then(|| cwd.as_ref().map(|path| path.to_string_lossy().into_owned()))
            .flatten();
        Ok(ConversationSummary {
            id,
            provider: ProviderId::Codex,
            kind,
            // Codex only fills `name` once a thread has been named, so an
            // unnamed one falls back to what it does carry — the same order
            // its own UI uses. A wall of "Untitled" rows is unusable.
            title: [
                thread.get("name"),
                thread.get("preview"),
                thread.get("firstUserMessage"),
            ]
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::trim)
            .find(|title| !title.is_empty())
            .map(one_line_title)
            .unwrap_or_else(|| "Untitled Codex thread".to_owned()),
            // The authoritative Codex project identity comes from
            // state_5.sqlite. A thread/list row only carries cwd, so it must
            // not invent a path-derived project ID.
            project_id: None,
            project_path,
            updated_at: parse_time(thread.get("updatedAt")),
            status: thread
                .pointer("/status/type")
                .or_else(|| thread.get("status"))
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned(),
            write_state: None,
            write_block_code: None,
        })
    }

    pub fn map_notification(&self, line: &str) -> anyhow::Result<ConversationEvent> {
        let value: Value = serde_json::from_str(line)?;
        Ok(self.map_notification_value(&value))
    }

    fn map_notification_value(&self, value: &Value) -> ConversationEvent {
        let method = value
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let params = value.get("params").cloned().unwrap_or_else(|| json!({}));
        match method {
            "item/agentMessage/delta" => ConversationEvent::Delta {
                text: params
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "thread/started" => ConversationEvent::Started(params),
            "turn/started" => ConversationEvent::ToolStarted(params),
            // A turn that ends in `failed` still arrives as `turn/completed`.
            // Reporting it as a completion leaves the phone showing a finished
            // turn with no answer and no reason, so the provider's own message
            // is forwarded as a failure instead.
            "turn/completed" => match turn_failure_message(&params) {
                Some(message) => ConversationEvent::TurnFailed(turn_failure(&params, message)),
                None => ConversationEvent::TurnCompleted(params),
            },
            // The app-server reports quota and upstream problems out of band.
            "error" => ConversationEvent::TurnFailed(turn_failure(
                &params,
                params
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .or_else(|| params.get("message").and_then(Value::as_str))
                    .unwrap_or("Codex reported an error")
                    .to_owned(),
            )),
            "item/completed" => ConversationEvent::ToolCompleted(params),
            "item/commandExecution/requestApproval" => {
                ConversationEvent::ApprovalRequested(normalize_approval(value, "command"))
            }
            "item/fileChange/requestApproval" => {
                ConversationEvent::ApprovalRequested(normalize_approval(value, "file"))
            }
            _ => ConversationEvent::Unsupported {
                raw_type: method.to_owned(),
                payload: params,
            },
        }
    }
}

pub struct CodexAdapter {
    executable: PathBuf,
    mapper: CodexMapper,
    status: ProviderStatus,
    events: broadcast::Sender<ConversationEvent>,
    rpc: Mutex<Option<Arc<RpcClient>>>,
    active_turns: Arc<RwLock<HashMap<String, String>>>,
    index_write_lock: Arc<std::sync::Mutex<()>>,
    host_bridge: Option<Arc<dyn CodexHostBridge>>,
}

impl CodexAdapter {
    pub fn new(executable: impl Into<PathBuf>, home: impl Into<PathBuf>) -> Self {
        let executable = executable.into();
        let (events, _) = broadcast::channel(256);
        Self {
            status: ProviderStatus {
                provider: ProviderId::Codex,
                available: true,
                executable_path: Some(executable.to_string_lossy().into_owned()),
                version: None,
                reason: None,
            },
            executable,
            mapper: CodexMapper::new(home.into()),
            events,
            rpc: Mutex::new(None),
            active_turns: Arc::new(RwLock::new(HashMap::new())),
            index_write_lock: Arc::new(std::sync::Mutex::new(())),
            host_bridge: None,
        }
    }

    pub fn with_host_bridge(mut self, bridge: Arc<dyn CodexHostBridge>) -> Self {
        self.host_bridge = Some(bridge);
        self
    }

    pub fn command_spec(&self) -> CommandSpec {
        CommandSpec {
            program: self.executable.to_string_lossy().into_owned(),
            args: vec!["app-server".into(), "--stdio".into()],
        }
    }

    pub fn approval_response(&self, allow: bool) -> Value {
        json!({"decision": if allow { "accept" } else { "decline" }})
    }

    pub fn rpc_id_key(id: &Value) -> String {
        id.as_str().map_or_else(|| id.to_string(), str::to_owned)
    }

    fn read_session_index(&self) -> Vec<ConversationSummary> {
        let path = self.mapper.home.join(".codex/session_index.jsonl");
        let Ok(file) = File::open(path) else {
            return Vec::new();
        };
        let content = StdBufReader::new(file)
            .lines()
            .take(4096)
            .filter_map(Result::ok)
            .filter(|line| line.len() <= 64 * 1024)
            .collect::<Vec<_>>()
            .join("\n");
        self.mapper.map_session_index(&content)
    }

    fn touch_recent_session(&self, id: &str) -> anyhow::Result<()> {
        let _guard = self
            .index_write_lock
            .lock()
            .map_err(|_| anyhow::anyhow!("recent-session index lock poisoned"))?;
        self.mapper.write_session_index_entry(id, Utc::now())
    }

    async fn client(&self) -> anyhow::Result<Arc<RpcClient>> {
        let mut slot = self.rpc.lock().await;
        if let Some(client) = slot.as_ref() {
            if client.is_alive() {
                return Ok(client.clone());
            }
            // The CLI went away. Drop it and start a new one, so a crash costs
            // one failed turn rather than every turn until the agent restarts.
            *slot = None;
            self.active_turns.write().await.clear();
        }
        let client = Arc::new(
            RpcClient::connect(
                self.command_spec(),
                self.mapper.clone(),
                self.events.clone(),
                self.active_turns.clone(),
            )
            .await?,
        );
        client
            .call(
                "initialize",
                json!({"clientInfo":{"name":"remote-ai","title":"RemoteAI","version":"0.1.0"}}),
            )
            .await?;
        client.notify("initialized", json!({})).await?;
        *slot = Some(client.clone());
        Ok(client)
    }

    async fn host_chat_bridge_for(
        &self,
        id: &str,
    ) -> anyhow::Result<Option<Arc<dyn CodexHostBridge>>> {
        let Some(bridge) = self.host_bridge.as_ref().cloned() else {
            return Ok(None);
        };
        let is_host_chat =
            bridge
                .list_chatgpt_conversations()
                .await?
                .into_iter()
                .any(|conversation| {
                    conversation.id == id
                        && conversation.provider == ProviderId::Codex
                        && conversation.kind == ConversationKind::Daily
                        && conversation.project_id.is_none()
                });
        Ok(is_host_chat.then_some(bridge))
    }
}

#[async_trait]
impl ProviderAdapter for CodexAdapter {
    async fn status(&self) -> ProviderStatus {
        let mut status = self.status.clone();
        status.reason = self.daily_catalog_diagnostic_code().map(str::to_owned);
        status
    }

    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        // `thread/list` answers one fixed-size page at a time. Reading only the
        // first page hides every older thread, which makes most projects look
        // as though they have no sessions at all.
        let client = self.client().await?;
        let mut conversations = Vec::new();
        let mut seen = HashSet::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_THREAD_LIST_PAGES {
            let mut params = json!({"sortDirection":"desc"});
            if let Some(cursor) = cursor.as_deref() {
                params["cursor"] = json!(cursor);
            }
            let result = client.call("thread/list", params).await?;
            for summary in self.mapper.map_thread_list_value(&result)? {
                if seen.insert(summary.id.clone()) {
                    conversations.push(summary);
                }
            }
            let next = result
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            match next {
                Some(next) if Some(&next) != cursor.as_ref() => cursor = Some(next),
                _ => break,
            }
        }
        conversations.sort_by_key(|summary| Reverse(summary.updated_at));
        Ok(conversations)
    }

    async fn list_daily_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        if let Some(bridge) = self.host_bridge.as_ref() {
            return Ok(bridge
                .list_chatgpt_conversations()
                .await?
                .into_iter()
                .filter(|conversation| {
                    conversation.provider == ProviderId::Codex
                        && conversation.kind == ConversationKind::Daily
                        && conversation.project_id.is_none()
                })
                .map(|mut conversation| {
                    conversation.project_path = None;
                    conversation
                })
                .collect());
        }
        // Without an injected host catalog, Codex's own thread list is the
        // provider's global conversation view — the same role Claude's desktop
        // session index plays. Returning an empty list here would leave the
        // Chats tab permanently unreadable and unwritable.
        Ok(self
            .list_conversations()
            .await?
            .into_iter()
            .map(|mut conversation| {
                conversation.kind = ConversationKind::Daily;
                conversation.project_id = None;
                conversation.project_path = None;
                conversation
            })
            .collect())
    }

    fn daily_catalog_diagnostic_code(&self) -> Option<&'static str> {
        // The Chats view now has a local source, so an empty list is a real
        // empty catalog. A provider that cannot be reached at all still
        // surfaces through the read error the gateway reports.
        None
    }

    async fn list_projects(&self) -> anyhow::Result<Vec<ProjectSummary>> {
        let database = self.mapper.home.join(".codex/state_5.sqlite");
        if !database.is_file() {
            return Ok(Vec::new());
        }
        let options = SqliteConnectOptions::new()
            .filename(database)
            .read_only(true)
            .create_if_missing(false);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        let rows = sqlx::query(
            "SELECT p.id, p.name, p.updated_at_ms, r.path
             FROM projects p
             LEFT JOIN project_roots r ON r.project_id = p.id
               AND NOT EXISTS (
                 SELECT 1 FROM project_roots earlier
                 WHERE earlier.project_id = p.id
                   AND (earlier.position < r.position
                     OR (earlier.position = r.position AND earlier.path < r.path))
               )
             ORDER BY p.position ASC, r.position ASC, r.path ASC",
        )
        .fetch_all(&pool)
        .await?;
        pool.close().await;

        let mut projects = Vec::new();
        for row in rows {
            let Some(path) = row.try_get::<Option<String>, _>("path")? else {
                continue;
            };
            let canonical_path = canonical_or_normalized(Path::new(&path));
            let name = row.try_get::<String, _>("name")?;
            let updated_at_ms = row.try_get::<i64, _>("updated_at_ms")?;
            let display_path = display_path(&canonical_path, &self.mapper.home);
            projects.push(ProjectSummary {
                id: row.try_get::<String, _>("id")?,
                provider: ProviderId::Codex,
                canonical_path: canonical_path.clone(),
                display_path,
                title: if name.trim().is_empty() {
                    Path::new(&canonical_path)
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or("Untitled Codex project")
                        .to_owned()
                } else {
                    name
                },
                updated_at: Utc
                    .timestamp_millis_opt(updated_at_ms)
                    .single()
                    .unwrap_or_else(Utc::now),
                available: Path::new(&canonical_path).is_dir(),
            });
        }
        projects.sort_by_key(|project| Reverse(project.updated_at));
        Ok(projects)
    }

    async fn list_project_conversations(
        &self,
        project_id: &str,
    ) -> anyhow::Result<Vec<ConversationSummary>> {
        let project = self
            .list_projects()
            .await?
            .into_iter()
            .find(|project| project.id == project_id);
        let Some(project) = project else {
            return Ok(Vec::new());
        };
        let mut conversations = self.list_conversations().await?;
        for conversation in &mut conversations {
            let Some(path) = conversation.project_path.as_deref() else {
                continue;
            };
            if canonical_or_normalized(Path::new(path)) == project.canonical_path {
                conversation.kind = ConversationKind::Project;
                conversation.project_id = Some(project.id.clone());
            }
        }
        Ok(conversations
            .into_iter()
            .filter(|conversation| conversation.project_id.as_deref() == Some(project_id))
            .collect())
    }

    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        if let Some(bridge) = self.host_chat_bridge_for(id).await? {
            return bridge.load_chatgpt_conversation(id, cursor).await;
        }
        let result = self
            .client()
            .await?
            .call("thread/read", json!({"threadId": id, "includeTurns": true}))
            .await;
        let result = match result {
            Ok(result) => result,
            // A thread that exists but has not received its first user message
            // yet refuses `includeTurns`. The phone opens the transcript before
            // that first turn exists, so this is an empty history, not a
            // failure the user should see.
            Err(error) if is_unmaterialized_thread(&error) => {
                return Ok(ConversationPage {
                    conversation_id: id.to_owned(),
                    events: Vec::new(),
                    next_cursor: None,
                });
            }
            Err(error) => return Err(error),
        };
        self.mapper.map_thread_read_value(&result, id, cursor)
    }

    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        if kind == ConversationKind::Daily
            && let Some(bridge) = self.host_bridge.as_ref()
        {
            return bridge.start_chatgpt_conversation(cwd).await;
        }
        // A Chat is not bound to a project directory, so it runs in the paired
        // user's HOME rather than wherever the agent process happens to live.
        let cwd = match kind {
            ConversationKind::Daily => cwd.or_else(|| Some(self.mapper.home.clone())),
            ConversationKind::Project => cwd,
        };
        let client = self.client().await?;
        let result = client
            .call(
                "thread/start",
                json!({
                    "cwd": cwd,
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "user"
                }),
            )
            .await?;
        let id = required_string(result.get("thread").unwrap_or(&result), "id")?;
        client.mark_loaded(&id).await;
        if kind == ConversationKind::Daily {
            self.touch_recent_session(&id)?;
        }
        Ok(id)
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        if let Some(bridge) = self.host_chat_bridge_for(id).await? {
            return bridge.resume_chatgpt_conversation(id).await;
        }
        let client = self.client().await?;
        client.load_thread(id).await?;
        Ok(())
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
        if let Some(bridge) = self.host_chat_bridge_for(id).await? {
            return bridge.send_chatgpt_message(id, text, attachments).await;
        }
        let mut input = vec![json!({"type":"text","text":text})];
        input.extend(attachments.into_iter().map(
            |path| json!({"type":"text","text":format!("Explicit attachment: {}", path.display())}),
        ));
        self.active_turns
            .write()
            .await
            .insert(id.to_owned(), "pending".into());
        let client = match self.client().await {
            Ok(client) => client,
            Err(error) => {
                self.active_turns.write().await.remove(id);
                return Err(error);
            }
        };
        // `turn/start` only accepts a thread this app-server process has
        // loaded. The phone is writing to a conversation that already exists on
        // the Mac, so resuming it here is exactly what pressing send asked for;
        // the gateway has already checked that no other writer holds it.
        if !client.is_loaded(id).await
            && let Err(error) = client.load_thread(id).await
        {
            self.active_turns.write().await.remove(id);
            return Err(error);
        }
        let result = match client
            .call("turn/start", json!({"threadId": id, "input": input}))
            .await
        {
            Ok(result) => result,
            Err(error) => {
                self.active_turns.write().await.remove(id);
                return Err(error);
            }
        };
        if let Some(turn_id) = result.pointer("/turn/id").and_then(Value::as_str) {
            self.active_turns
                .write()
                .await
                .insert(id.to_owned(), turn_id.to_owned());
        }
        if self
            .read_session_index()
            .iter()
            .any(|conversation| conversation.id == id)
        {
            self.touch_recent_session(id)?;
        }
        Ok(())
    }

    async fn decide_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> anyhow::Result<()> {
        self.client()
            .await?
            .respond(
                request_id,
                self.approval_response(decision == ApprovalDecision::AllowOnce),
            )
            .await
    }

    async fn interrupt(&self, id: &str) -> anyhow::Result<()> {
        let turn_id = self
            .active_turns
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no active turn for thread"))?;
        self.client()
            .await?
            .call("turn/interrupt", json!({"threadId": id, "turnId": turn_id}))
            .await?;
        Ok(())
    }

    async fn write_availability(&self, id: &str) -> anyhow::Result<WriteState> {
        if self.active_turns.read().await.contains_key(id) {
            Ok(WriteState::Busy)
        } else {
            Ok(WriteState::Available)
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent> {
        self.events.subscribe()
    }
}

struct RpcClient {
    stdin: Mutex<ChildStdin>,
    _child: Mutex<Child>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<anyhow::Result<Value>>>>>,
    next_id: AtomicU64,
    /// Threads this app-server process has started or resumed. `turn/start`
    /// answers "thread not found" for anything else, and the set has to live
    /// with the process because a restart loses every loaded thread.
    loaded_threads: Mutex<HashSet<String>>,
    /// Cleared when the process goes away or a write to it fails. A cached
    /// handle to a dead CLI can never carry another turn, so every later send
    /// would fail with a broken pipe until the agent itself was restarted.
    alive: Arc<AtomicBool>,
}

impl RpcClient {
    async fn connect(
        spec: CommandSpec,
        mapper: CodexMapper,
        events: broadcast::Sender<ConversationEvent>,
        active_turns: Arc<RwLock<HashMap<String, String>>>,
    ) -> anyhow::Result<Self> {
        let mut child = Command::new(&spec.program)
            .args(&spec.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("missing stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("missing stdout"))?;
        if let Some(mut stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let _ = tokio::io::copy(&mut stderr, &mut tokio::io::sink()).await;
            });
        }
        let pending: Arc<Mutex<HashMap<String, oneshot::Sender<anyhow::Result<Value>>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let reader_pending = pending.clone();
        let alive = Arc::new(AtomicBool::new(true));
        let reader_alive = alive.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if value.get("method").is_none()
                    && let Some(id) = value.get("id")
                    && let Some(sender) = reader_pending
                        .lock()
                        .await
                        .remove(&CodexAdapter::rpc_id_key(id))
                {
                    let result = if let Some(error) = value.get("error") {
                        Err(anyhow::anyhow!("Codex RPC error: {error}"))
                    } else {
                        Ok(value.get("result").cloned().unwrap_or(Value::Null))
                    };
                    let _ = sender.send(result);
                    continue;
                }
                track_turns(&value, &active_turns).await;
                let _ = events.send(mapper.map_notification_value(&value));
            }
            // stdout closed: the process is gone. Fail the calls waiting on it
            // instead of letting each one burn its own timeout.
            reader_alive.store(false, Ordering::Relaxed);
            for (_, sender) in reader_pending.lock().await.drain() {
                let _ = sender.send(Err(anyhow::anyhow!("Codex app-server exited")));
            }
        });
        Ok(Self {
            stdin: Mutex::new(stdin),
            _child: Mutex::new(child),
            pending,
            next_id: AtomicU64::new(1),
            loaded_threads: Mutex::new(HashSet::new()),
            alive,
        })
    }

    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    async fn mark_loaded(&self, id: &str) {
        self.loaded_threads.lock().await.insert(id.to_owned());
    }

    async fn is_loaded(&self, id: &str) -> bool {
        self.loaded_threads.lock().await.contains(id)
    }

    /// Resume a thread into this process and remember that it is loaded.
    async fn load_thread(&self, id: &str) -> anyhow::Result<()> {
        self.call(
            "thread/resume",
            json!({
                "threadId": id,
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user"
            }),
        )
        .await?;
        self.mark_loaded(id).await;
        Ok(())
    }

    async fn call(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed).to_string();
        let (sender, receiver) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), sender);
        self.write(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .await?;
        tokio::time::timeout(std::time::Duration::from_secs(30), receiver)
            .await
            .map_err(|_| anyhow::anyhow!("Codex RPC timed out"))??
    }

    async fn notify(&self, method: &str, params: Value) -> anyhow::Result<()> {
        self.write(&json!({"jsonrpc":"2.0","method":method,"params":params}))
            .await
    }

    async fn respond(&self, id: &str, result: Value) -> anyhow::Result<()> {
        let id_value = serde_json::from_str::<Value>(id).unwrap_or_else(|_| json!(id));
        self.write(&json!({"jsonrpc":"2.0","id":id_value,"result":result}))
            .await
    }

    async fn write(&self, value: &Value) -> anyhow::Result<()> {
        let payload = serde_json::to_string(value)?;
        let mut stdin = self.stdin.lock().await;
        let result = async {
            stdin.write_all(payload.as_bytes()).await?;
            stdin.write_all(b"\n").await?;
            stdin.flush().await?;
            Ok::<(), std::io::Error>(())
        }
        .await;
        if result.is_err() {
            self.alive.store(false, Ordering::Relaxed);
        }
        Ok(result?)
    }
}

async fn track_turns(value: &Value, active: &RwLock<HashMap<String, String>>) {
    let method = value.get("method").and_then(Value::as_str);
    let thread_id = value.pointer("/params/threadId").and_then(Value::as_str);
    match (method, thread_id) {
        (Some("turn/started"), Some(thread_id)) => {
            if let Some(turn_id) = value.pointer("/params/turn/id").and_then(Value::as_str) {
                active
                    .write()
                    .await
                    .insert(thread_id.to_owned(), turn_id.to_owned());
            }
        }
        (Some("turn/completed"), Some(thread_id)) => {
            active.write().await.remove(thread_id);
        }
        _ => {}
    }
}

fn normalize_codex_item(
    conversation_id: &str,
    turn_index: usize,
    item_index: usize,
    item: &Value,
) -> Vec<Value> {
    let stable_id = item
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{conversation_id}:turn:{turn_index}:item:{item_index}"));
    let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
    let text = item
        .get("text")
        .and_then(Value::as_str)
        .or_else(|| item.pointer("/content/0/text").and_then(Value::as_str));
    match item_type {
        "userMessage" | "user_message" | "user" => text
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                vec![json!({
                    "type": "conversation.user_message",
                    "payload": {"messageId": stable_id, "role": "user", "text": value}
                })]
            })
            .unwrap_or_default(),
        "agentMessage" | "agent_message" | "assistant" => text
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                vec![json!({
                    "type": "conversation.message_completed",
                    "payload": {"messageId": stable_id, "role": "assistant", "text": value}
                })]
            })
            .unwrap_or_default(),
        "reasoning" | "reasoningMessage" => text
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                vec![
                    json!({
                        "type": "conversation.reasoning_delta",
                        "payload": {"reasoningId": stable_id, "text": value}
                    }),
                    json!({
                        "type": "conversation.reasoning_completed",
                        "payload": {"reasoningId": stable_id, "text": value}
                    }),
                ]
            })
            .unwrap_or_default(),
        "commandExecution" | "command_execution" | "fileChange" | "file_change" | "tool" => {
            let name = if item_type.to_ascii_lowercase().contains("command") {
                "command"
            } else if item_type.to_ascii_lowercase().contains("file") {
                "file_change"
            } else {
                "tool"
            };
            vec![json!({
                "type": "tool.started",
                "payload": {"toolCallId": stable_id, "name": name, "detail": item.get("command").or_else(|| item.get("path"))}
            })]
        }
        "turnCompleted" | "turn_completed" | "turn" => {
            let failed = item
                .get("status")
                .and_then(Value::as_str)
                .is_some_and(|status| matches!(status, "failed" | "error"));
            vec![json!({
                "type": if failed { "turn.failed" } else { "turn.completed" },
                "payload": {"conversationId": conversation_id}
            })]
        }
        _ => Vec::new(),
    }
}

/// The provider message for a turn that ended in failure, if it did.
fn turn_failure_message(params: &Value) -> Option<String> {
    let status = params
        .pointer("/turn/status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(status, "failed" | "error") {
        return None;
    }
    Some(
        params
            .pointer("/turn/error/message")
            .and_then(Value::as_str)
            .unwrap_or("the Codex turn failed")
            .to_owned(),
    )
}

/// Shape a failure the phone can render: a stable code plus the provider's
/// own wording, so the user always learns why a turn produced no answer.
fn turn_failure(params: &Value, message: String) -> Value {
    json!({
        "conversationId": params.get("threadId"),
        "turnId": params.pointer("/turn/id"),
        "code": "turn_failed",
        "message": message,
    })
}

fn normalize_approval(value: &Value, category: &str) -> Value {
    let params = value.get("params").cloned().unwrap_or_else(|| json!({}));
    json!({
        "id": value.get("id").map(Value::to_string).unwrap_or_default(),
        "provider": "codex",
        "conversationId": params.get("threadId"),
        "category": category,
        "title": if category == "command" { "Run command" } else { "Change files" },
        "detail": params.get("command").or_else(|| params.get("reason")),
        "cwd": params.get("cwd"),
        "createdAt": params.get("startedAtMs")
    })
}

/// Recognize the app-server's "no first user message yet" rejection. The
/// wording is the only signal it gives; every other read failure stays an
/// error the phone is told about.
fn is_unmaterialized_thread(error: &anyhow::Error) -> bool {
    error.to_string().contains("not materialized")
}

/// A list row is one line. Collapse whitespace and bound the length so a
/// pasted prompt or a delegation block cannot become the whole row.
fn one_line_title(raw: &str) -> String {
    const MAX_TITLE_CHARS: usize = 80;
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= MAX_TITLE_CHARS {
        return collapsed;
    }
    let mut title = collapsed.chars().take(MAX_TITLE_CHARS).collect::<String>();
    title.push('…');
    title
}

fn required_string(value: &Value, key: &str) -> anyhow::Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("missing string field {key}"))
}

fn same_path(left: &Path, right: &Path) -> bool {
    left.components().eq(right.components())
}

fn canonical_or_normalized(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn display_path(path: &str, home: &Path) -> String {
    let path = Path::new(path);
    match path.strip_prefix(home) {
        Ok(relative) if relative.as_os_str().is_empty() => "~".to_owned(),
        Ok(relative) => format!("~/{}", relative.to_string_lossy()),
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

fn parse_time(value: Option<&Value>) -> DateTime<Utc> {
    if let Some(seconds) = value.and_then(Value::as_i64) {
        return Utc
            .timestamp_opt(seconds, 0)
            .single()
            .unwrap_or_else(Utc::now);
    }
    value
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or_else(Utc::now)
}
