use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader as StdBufReader};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, RwLock, broadcast};

use super::{ConversationPage, ProviderAdapter};
use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProviderId,
    ProviderStatus,
};

const MAX_METADATA_LINE_BYTES: usize = 64 * 1024;
/// Upper bound on one history page. Real transcripts are long, so the agent —
/// not the client — decides how much one read may cost.
const DEFAULT_HISTORY_PAGE_SIZE: usize = 50;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ClaudeMapper {
    home: PathBuf,
}

impl ClaudeMapper {
    pub fn new(home: PathBuf) -> Self {
        Self { home }
    }

    pub fn classify(&self, cwd: PathBuf) -> ConversationKind {
        if same_path(&cwd, &self.home) {
            ConversationKind::Daily
        } else {
            ConversationKind::Project
        }
    }

    pub fn map_line(&self, line: &str) -> anyhow::Result<ConversationEvent> {
        let value: Value = serde_json::from_str(line)?;
        Ok(self.map_value(&value))
    }

    fn map_value(&self, value: &Value) -> ConversationEvent {
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        match kind {
            "system" if value.get("subtype").and_then(Value::as_str) == Some("init") => {
                ConversationEvent::Started(json!({
                    "provider": "claude",
                    "sessionId": value.get("session_id"),
                    "cwd": value.get("cwd"),
                    "model": value.get("model")
                }))
            }
            "stream_event"
                if value.pointer("/event/delta/type").and_then(Value::as_str)
                    == Some("text_delta") =>
            {
                ConversationEvent::Delta {
                    text: value
                        .pointer("/event/delta/text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                }
            }
            "assistant" => {
                let content = value.pointer("/message/content").and_then(Value::as_array);
                if let Some(tool) =
                    content.and_then(|items| items.iter().find(|item| item["type"] == "tool_use"))
                {
                    ConversationEvent::ToolStarted(json!({
                        "tool": tool.get("name"),
                        "id": tool.get("id"),
                        "input": tool.get("input")
                    }))
                } else {
                    ConversationEvent::Unsupported {
                        raw_type: kind.into(),
                        payload: value.clone(),
                    }
                }
            }
            "control_request" => {
                let request = value.get("request").cloned().unwrap_or_else(|| json!({}));
                let tool = request
                    .get("tool_name")
                    .and_then(Value::as_str)
                    .unwrap_or("tool");
                ConversationEvent::ApprovalRequested(json!({
                    "id": value.get("request_id"),
                    "provider": "claude",
                    "conversationId": value.get("session_id").or_else(|| request.get("session_id")),
                    "category": if tool.eq_ignore_ascii_case("bash") { "command" } else { "file" },
                    "title": format!("Allow {tool}"),
                    "detail": request.pointer("/input/command").or_else(|| request.get("input")),
                    "cwd": request.get("cwd"),
                    "decisionOptions": ["allow_once", "deny"]
                }))
            }
            "user" => ConversationEvent::ToolCompleted(
                value
                    .pointer("/message/content")
                    .cloned()
                    .unwrap_or(Value::Null),
            ),
            "result" if value.get("is_error").and_then(Value::as_bool) == Some(true) => {
                ConversationEvent::TurnFailed(value.clone())
            }
            "result" => ConversationEvent::TurnCompleted(value.clone()),
            _ => ConversationEvent::Unsupported {
                raw_type: kind.to_owned(),
                payload: value.clone(),
            },
        }
    }
}

pub struct ClaudeAdapter {
    executable: PathBuf,
    mapper: ClaudeMapper,
    status: ProviderStatus,
    events: broadcast::Sender<ConversationEvent>,
    sessions: RwLock<HashMap<String, Arc<ClaudeSession>>>,
    session_paths: RwLock<HashMap<String, PathBuf>>,
    /// Placeholder id handed to the phone -> the id Claude itself assigned.
    adopted_ids: Arc<RwLock<HashMap<String, String>>>,
    history_page_size: usize,
}

struct ClaudeSession {
    stdin: Mutex<ChildStdin>,
    _child: Mutex<Child>,
}

impl ClaudeAdapter {
    pub fn new(executable: impl Into<PathBuf>, home: impl Into<PathBuf>) -> Self {
        let executable = executable.into();
        let (events, _) = broadcast::channel(256);
        Self {
            status: ProviderStatus {
                provider: ProviderId::Claude,
                available: true,
                executable_path: Some(executable.to_string_lossy().into_owned()),
                version: None,
                reason: None,
            },
            executable,
            mapper: ClaudeMapper::new(home.into()),
            events,
            sessions: RwLock::new(HashMap::new()),
            session_paths: RwLock::new(HashMap::new()),
            adopted_ids: Arc::new(RwLock::new(HashMap::new())),
            history_page_size: DEFAULT_HISTORY_PAGE_SIZE,
        }
    }

    /// The id Claude assigned to a session this agent started, once its first
    /// record arrives. Until then the placeholder is all anyone has.
    pub async fn resolved_session_id(&self, id: &str) -> Option<String> {
        self.adopted_ids.read().await.get(id).cloned()
    }

    /// Narrow the page size. Tests use it to exercise paging on small
    /// fixtures; production keeps the default bound.
    pub fn with_history_page_size(mut self, size: usize) -> Self {
        self.history_page_size = size.max(1);
        self
    }

    pub fn command_spec(&self, resume: Option<&str>) -> CommandSpec {
        let mut args = vec![
            "--print",
            // The CLI rejects `--print --output-format stream-json` without
            // this and exits 1 before emitting a single event.
            "--verbose",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--include-hook-events",
            "--permission-mode",
            "manual",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        if let Some(session) = resume {
            args.extend(["--resume".into(), session.into()]);
        }
        CommandSpec {
            program: self.executable.to_string_lossy().into_owned(),
            args,
        }
    }

    async fn spawn_session(
        &self,
        resume: Option<&str>,
        cwd: Option<&Path>,
        local_id: &str,
    ) -> anyhow::Result<Arc<ClaudeSession>> {
        let spec = self.command_spec(resume);
        let mut command = Command::new(&spec.program);
        command.args(&spec.args);
        if let Some(cwd) = cwd {
            // Claude records the session under the directory its process runs
            // in. Passing a cwd in the first message does nothing, which is how
            // phone-started project sessions used to land in the agent's own
            // directory and never show up on the Mac.
            command.current_dir(cwd);
        }
        let mut child = command
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
        let events = self.events.clone();
        let mapper = self.mapper.clone();
        let adopted = self.adopted_ids.clone();
        let local_id = local_id.to_owned();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Some(real) = session_id_from_init(&line)
                    && real != local_id
                {
                    adopted.write().await.insert(local_id.clone(), real);
                }
                if let Ok(value) = mapper.map_line(&line) {
                    let _ = events.send(value);
                }
            }
        });
        Ok(Arc::new(ClaudeSession {
            stdin: Mutex::new(stdin),
            _child: Mutex::new(child),
        }))
    }

    async fn write(session: &ClaudeSession, value: Value) -> anyhow::Result<()> {
        let mut stdin = session.stdin.lock().await;
        stdin
            .write_all(serde_json::to_string(&value)?.as_bytes())
            .await?;
        stdin.write_all(b"\n").await?;
        stdin.flush().await?;
        Ok(())
    }
}

#[async_trait]
impl ProviderAdapter for ClaudeAdapter {
    async fn status(&self) -> ProviderStatus {
        self.status.clone()
    }

    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        // Claude's supported project/session files are metadata indexes. We intentionally do not
        // copy transcript bodies or credentials into Agent storage.
        let projects = self.mapper.home.join(".claude/projects");
        let mut pending = vec![projects];
        let mut conversations = Vec::new();
        let mut session_paths = HashMap::new();
        while let Some(directory) = pending.pop() {
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            for entry in entries {
                let entry = entry?;
                let path = entry.path();
                let file_type = entry.file_type()?;
                if file_type.is_dir() {
                    pending.push(path);
                } else if file_type.is_file()
                    && path.extension().and_then(|extension| extension.to_str()) == Some("jsonl")
                    && let Some(conversation) = read_conversation_metadata(&self.mapper, &path)?
                {
                    session_paths.entry(conversation.id.clone()).or_insert(path);
                    conversations.push(conversation);
                }
            }
        }
        conversations.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        *self.session_paths.write().await = session_paths;
        Ok(conversations)
    }

    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        // A session started from the phone is addressed by its placeholder id
        // until a refresh; resolve it to the transcript Claude actually wrote.
        let resolved = self.resolved_session_id(id).await;
        let lookup = resolved.as_deref().unwrap_or(id);
        let path = self.session_paths.read().await.get(lookup).cloned();
        let Some(path) = path else {
            // A session this agent just started has no transcript on disk yet.
            // That is an empty history, not a failure — the phone opens the
            // screen before the first turn exists.
            anyhow::ensure!(
                self.sessions.read().await.contains_key(id),
                "session is not indexed"
            );
            return Ok(ConversationPage {
                conversation_id: id.to_owned(),
                events: Vec::new(),
                next_cursor: None,
            });
        };
        let events = read_conversation_events(lookup, &path)?;
        let start = cursor
            .as_deref()
            .map(|cursor| cursor.parse::<usize>())
            .transpose()
            .map_err(|_| anyhow::anyhow!("invalid history cursor"))?
            .unwrap_or(0);
        anyhow::ensure!(start <= events.len(), "history cursor is out of range");
        let end = (start + self.history_page_size).min(events.len());
        Ok(ConversationPage {
            conversation_id: id.to_owned(),
            events: events[start..end].to_vec(),
            next_cursor: (end < events.len()).then(|| end.to_string()),
        })
    }

    async fn start(&self, _kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        if let Some(cwd) = cwd.as_deref() {
            anyhow::ensure!(cwd.is_dir(), "project directory is not available");
        }
        let id = format!("pending-{}", uuid::Uuid::new_v4());
        let session = self.spawn_session(None, cwd.as_deref(), &id).await?;
        self.sessions.write().await.insert(id.clone(), session);
        Ok(id)
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        // Resume in the session's own project, so the resumed turns are stored
        // where the rest of that session lives.
        let cwd = self
            .list_conversations()
            .await
            .unwrap_or_default()
            .into_iter()
            .find(|summary| summary.id == id)
            .and_then(|summary| summary.project_path)
            .map(PathBuf::from)
            .filter(|path| path.is_dir());
        let session = self.spawn_session(Some(id), cwd.as_deref(), id).await?;
        self.sessions.write().await.insert(id.to_owned(), session);
        Ok(())
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
        let session = self
            .sessions
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("session is not active"))?;
        let mut content = text;
        if !attachments.is_empty() {
            content.push_str("\nExplicit attachments:\n");
            content.push_str(
                &attachments
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
        }
        Self::write(
            &session,
            json!({"type":"user","message":{"role":"user","content":content}}),
        )
        .await
    }

    async fn decide_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> anyhow::Result<()> {
        let behavior = if decision == ApprovalDecision::AllowOnce {
            "allow"
        } else {
            "deny"
        };
        for session in self.sessions.read().await.values() {
            Self::write(
                session,
                json!({
                    "type":"control_response",
                    "request_id":request_id,
                    "response":{"subtype":"success","response":{"behavior":behavior}}
                }),
            )
            .await?;
        }
        Ok(())
    }

    async fn interrupt(&self, id: &str) -> anyhow::Result<()> {
        let session = self
            .sessions
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("session is not active"))?;
        Self::write(
            &session,
            json!({"type":"control_response","response":{"subtype":"interrupt"}}),
        )
        .await
    }

    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent> {
        self.events.subscribe()
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    left.components().eq(right.components())
}

fn read_conversation_metadata(
    mapper: &ClaudeMapper,
    path: &Path,
) -> anyhow::Result<Option<ConversationSummary>> {
    let file = File::open(path)?;
    let mut metadata = SessionMetadata::default();
    for line in StdBufReader::new(file).lines() {
        let line = match line {
            Ok(line) if line.len() <= MAX_METADATA_LINE_BYTES => line,
            Ok(_) | Err(_) => continue,
        };
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(_) => continue,
        };
        metadata.session_id = metadata
            .session_id
            .or_else(|| string_field(&value, &["sessionId", "session_id"]));
        metadata.cwd = metadata.cwd.or_else(|| string_field(&value, &["cwd"]));
        metadata.title = metadata.title.or_else(|| first_user_text(&value));
        if metadata.session_id.is_some() && metadata.cwd.is_some() && metadata.title.is_some() {
            break;
        }
    }

    let id = metadata.session_id.or_else(|| {
        path.file_stem()
            .and_then(|stem| stem.to_str())
            .map(str::to_owned)
    });
    let Some(id) = id else {
        return Ok(None);
    };
    let cwd = metadata
        .cwd
        .map(PathBuf::from)
        .unwrap_or_else(|| mapper.home.clone());
    let updated_at = fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .map(DateTime::<Utc>::from)
        .unwrap_or_else(|_| Utc::now());
    Ok(Some(ConversationSummary {
        id,
        provider: ProviderId::Claude,
        kind: mapper.classify(cwd.clone()),
        title: metadata
            .title
            .unwrap_or_else(|| "Untitled Claude session".into()),
        project_id: None,
        project_path: (mapper.classify(cwd.clone()) == ConversationKind::Project)
            .then(|| cwd.to_string_lossy().into_owned()),
        updated_at,
        status: "idle".into(),
        write_state: None,
        write_block_code: None,
    }))
}

fn read_conversation_events(session_id: &str, path: &Path) -> anyhow::Result<Vec<Value>> {
    let file = File::open(path)?;
    let mut events = Vec::new();
    for (line_number, line) in StdBufReader::new(file).lines().enumerate() {
        let line = match line {
            Ok(line) if line.len() <= MAX_METADATA_LINE_BYTES => line,
            Ok(_) | Err(_) => continue,
        };
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(_) => continue,
        };
        events.extend(normalize_history_record(session_id, line_number, &value));
    }
    Ok(events)
}

/// The session id Claude reports in its `system`/`init` record.
fn session_id_from_init(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type").and_then(Value::as_str) != Some("system") {
        return None;
    }
    value
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

fn normalize_history_record(session_id: &str, line_number: usize, value: &Value) -> Vec<Value> {
    let kind = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let record_id = value
        .get("uuid")
        .or_else(|| value.get("id"))
        .or_else(|| value.get("messageId"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{session_id}:{line_number}"));
    match kind {
        "system" => Vec::new(),
        "user" => normalize_user_record(&record_id, value),
        "assistant" => normalize_assistant_record(&record_id, value),
        "result" => {
            let event_type = if value.get("is_error").and_then(Value::as_bool) == Some(true) {
                "turn.failed"
            } else {
                "turn.completed"
            };
            vec![json!({"type": event_type, "payload": {}})]
        }
        // A stored transcript is mostly bookkeeping — queue operations,
        // attachments, hook records. There is nothing to render, so it must
        // not occupy a page slot and leave the phone staring at a blank
        // transcript. Unknown *live* events still degrade to `unsupported`.
        _ => Vec::new(),
    }
}

fn normalize_user_record(record_id: &str, value: &Value) -> Vec<Value> {
    let Some(content) = value.pointer("/message/content") else {
        return Vec::new();
    };
    if let Some(items) = content.as_array()
        && let Some(tool) = items
            .iter()
            .find(|item| item.get("type").and_then(Value::as_str) == Some("tool_result"))
    {
        let mut payload = json!({
            "toolId": tool.get("tool_use_id").cloned().unwrap_or(Value::Null)
        });
        if let Some(text) = content_text(tool.get("content")) {
            payload["text"] = Value::String(text);
        }
        return vec![json!({"type": "tool.completed", "payload": payload})];
    }
    let Some(text) = content_text(Some(content)) else {
        return Vec::new();
    };
    vec![json!({
        "type": "conversation.user_message",
        "payload": {"messageId": record_id, "role": "user", "text": text}
    })]
}

fn normalize_assistant_record(record_id: &str, value: &Value) -> Vec<Value> {
    let Some(items) = value.pointer("/message/content").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut events = Vec::new();
    for (index, item) in items.iter().enumerate() {
        match item.get("type").and_then(Value::as_str) {
            Some("thinking") => {
                // Claude Code stores a signature-only block when the reasoning
                // body was not persisted; an empty disclosure is noise.
                if let Some(text) = item
                    .get("thinking")
                    .and_then(Value::as_str)
                    .filter(|text| !text.trim().is_empty())
                {
                    let reasoning_id = if index == 0 {
                        record_id.to_owned()
                    } else {
                        format!("{record_id}:{index}")
                    };
                    events.push(json!({
                        "type": "conversation.reasoning_completed",
                        "payload": {"reasoningId": reasoning_id, "text": text}
                    }));
                }
            }
            Some("text") => {
                if let Some(text) = item.get("text").and_then(Value::as_str) {
                    events.push(json!({
                        "type": "conversation.message_completed",
                        "payload": {"messageId": record_id, "role": "assistant", "text": text}
                    }));
                }
            }
            Some("tool_use") => {
                events.push(json!({
                    "type": "tool.started",
                    "payload": {
                        "toolId": item.get("id").cloned().unwrap_or(Value::Null),
                        "name": item.get("name").cloned().unwrap_or(Value::Null)
                    }
                }));
            }
            _ => {}
        }
    }
    events
}

fn content_text(value: Option<&Value>) -> Option<String> {
    let text = match value? {
        Value::String(text) => text.clone(),
        Value::Array(items) => items
            .iter()
            .filter_map(|item| {
                (item.get("type").and_then(Value::as_str) == Some("text"))
                    .then(|| item.get("text").and_then(Value::as_str))
                    .flatten()
            })
            .collect::<Vec<_>>()
            .join(""),
        _ => return None,
    };
    (!text.is_empty()).then_some(text)
}

#[derive(Default)]
struct SessionMetadata {
    session_id: Option<String>,
    cwd: Option<String>,
    title: Option<String>,
}

fn string_field(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn first_user_text(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("user") {
        return None;
    }
    let content = value.pointer("/message/content")?;
    let text = match content {
        Value::String(text) => Some(text.as_str()),
        Value::Array(items) => items.iter().find_map(|item| {
            (item.get("type").and_then(Value::as_str) == Some("text"))
                .then(|| item.get("text").and_then(Value::as_str))
                .flatten()
        }),
        _ => None,
    }?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.chars().take(256).collect())
}

#[allow(dead_code)]
fn _metadata_time(value: Option<&Value>) -> DateTime<Utc> {
    value
        .and_then(Value::as_str)
        .and_then(|raw| DateTime::parse_from_rfc3339(raw).ok())
        .map(|time| time.with_timezone(&Utc))
        .unwrap_or_else(Utc::now)
}
