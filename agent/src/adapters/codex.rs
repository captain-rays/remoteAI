use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader as StdBufReader, Write as StdWrite};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, RwLock, broadcast, oneshot};

static INDEX_TEMP_COUNTER: AtomicU64 = AtomicU64::new(1);

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
            title: thread
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("Untitled Codex thread")
                .to_owned(),
            project_id: project_path.as_deref().map(project_id),
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
            "turn/completed" => ConversationEvent::TurnCompleted(params),
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
        }
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
            return Ok(client.clone());
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
}

#[async_trait]
impl ProviderAdapter for CodexAdapter {
    async fn status(&self) -> ProviderStatus {
        self.status.clone()
    }

    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        let indexed = self.read_session_index();
        let rpc_result = match self.client().await {
            Ok(client) => {
                client
                    .call("thread/list", json!({"sortDirection":"desc"}))
                    .await
            }
            Err(error) => Err(error),
        };
        let mut conversations = match rpc_result {
            Ok(result) => self.mapper.map_thread_list_value(&result)?,
            Err(_error) if !indexed.is_empty() => indexed.clone(),
            Err(error) => return Err(error),
        };

        let existing: HashSet<_> = conversations
            .iter()
            .map(|summary| summary.id.clone())
            .collect();
        conversations.extend(
            indexed
                .into_iter()
                .filter(|summary| !existing.contains(&summary.id)),
        );
        conversations.sort_by_key(|summary| Reverse(summary.updated_at));
        Ok(conversations)
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
             ORDER BY p.position ASC, r.position ASC",
        )
        .fetch_all(&pool)
        .await?;
        pool.close().await;

        let mut projects = Vec::new();
        let mut seen_paths = HashSet::new();
        for row in rows {
            let Some(path) = row.try_get::<Option<String>, _>("path")? else {
                continue;
            };
            let canonical_path = canonical_or_normalized(Path::new(&path));
            if !seen_paths.insert(canonical_path.clone()) {
                continue;
            }
            let name = row.try_get::<String, _>("name")?;
            let updated_at_ms = row.try_get::<i64, _>("updated_at_ms")?;
            let display_path = display_path(&canonical_path, &self.mapper.home);
            projects.push(ProjectSummary {
                id: project_id(&canonical_path),
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

    async fn load_conversation(
        &self,
        id: &str,
        _cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        let result = self
            .client()
            .await?
            .call("thread/read", json!({"threadId": id, "includeTurns": true}))
            .await?;
        self.mapper.map_thread_read_value(&result, id, _cursor)
    }

    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        let result = self
            .client()
            .await?
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
        if kind == ConversationKind::Daily {
            self.touch_recent_session(&id)?;
        }
        Ok(id)
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        self.client()
            .await?
            .call(
                "thread/resume",
                json!({
                    "threadId": id,
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "user"
                }),
            )
            .await?;
        Ok(())
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
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
        });
        Ok(Self {
            stdin: Mutex::new(stdin),
            _child: Mutex::new(child),
            pending,
            next_id: AtomicU64::new(1),
        })
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
        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(serde_json::to_string(value)?.as_bytes())
            .await?;
        stdin.write_all(b"\n").await?;
        stdin.flush().await?;
        Ok(())
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

fn project_id(path: &str) -> String {
    format!("codex:{:x}", Sha256::digest(path.as_bytes()))
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
