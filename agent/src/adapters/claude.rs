use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader as StdBufReader};
use std::path::{Component, Path, PathBuf};
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
    ProviderStatus, WriteState,
};

const MAX_METADATA_LINE_BYTES: usize = 64 * 1024;
/// Upper bound on one history page. Real transcripts are long, so the agent —
/// not the client — decides how much one read may cost.
const DEFAULT_HISTORY_PAGE_SIZE: usize = 50;
const MAX_DESKTOP_DEPTH: usize = 8;

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

    pub fn map_line_for_session(
        &self,
        line: &str,
        public_id: &str,
    ) -> anyhow::Result<ConversationEvent> {
        Ok(remap_event_session_id(self.map_line(line)?, public_id))
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
    desktop_sessions: RwLock<HashMap<String, DesktopSessionTarget>>,
    /// Placeholder id handed to the phone -> the id Claude itself assigned.
    adopted_ids: Arc<RwLock<HashMap<String, String>>>,
    history_page_size: usize,
}

#[derive(Debug, Clone)]
struct DesktopSessionTarget {
    cli_id: Option<String>,
    cwd: PathBuf,
    user_selected_folders: Vec<PathBuf>,
    transcript_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
struct DesktopSessionMeta {
    desktop_id: String,
    cli_id: Option<String>,
    cwd: PathBuf,
    title: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    user_selected_folders: Vec<PathBuf>,
    transcript_path: Option<PathBuf>,
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
            desktop_sessions: RwLock::new(HashMap::new()),
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
                if let Ok(value) = mapper.map_line_for_session(&line, &local_id) {
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

    async fn refresh_desktop_index(&self) -> anyhow::Result<Vec<DesktopSessionMeta>> {
        let desktop_sessions = collect_desktop_sessions(&self.mapper.home)?;
        let mut targets = HashMap::new();
        for desktop in &desktop_sessions {
            targets.insert(
                desktop.desktop_id.clone(),
                DesktopSessionTarget {
                    cli_id: desktop.cli_id.clone(),
                    cwd: desktop.cwd.clone(),
                    user_selected_folders: desktop.user_selected_folders.clone(),
                    transcript_path: desktop.transcript_path.clone(),
                },
            );
        }
        *self.desktop_sessions.write().await = targets;
        Ok(desktop_sessions)
    }

    fn desktop_summary(
        &self,
        desktop: &DesktopSessionMeta,
        kind: ConversationKind,
        project_id: Option<String>,
        project_path: Option<String>,
    ) -> ConversationSummary {
        ConversationSummary {
            id: desktop.desktop_id.clone(),
            provider: ProviderId::Claude,
            kind,
            title: desktop.title.clone(),
            project_id,
            project_path,
            updated_at: desktop.updated_at.max(desktop.created_at),
            status: "idle".into(),
            write_state: Some(if desktop.cli_id.is_some() {
                WriteState::Available
            } else {
                WriteState::Unavailable
            }),
            write_block_code: desktop
                .cli_id
                .is_none()
                .then(|| "claude_cli_session_unavailable".into()),
        }
    }
}

#[async_trait]
impl ProviderAdapter for ClaudeAdapter {
    async fn status(&self) -> ProviderStatus {
        self.status.clone()
    }

    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        let desktop_root = self
            .mapper
            .home
            .join("Library/Application Support/Claude/claude-code-sessions");
        let legacy_desktop_root = self
            .mapper
            .home
            .join("Library/Application Support/Claude/local-agent-mode-sessions");
        if desktop_root.exists() || legacy_desktop_root.exists() {
            let desktop_sessions = self.refresh_desktop_index().await?;
            let mut conversations = desktop_sessions
                .iter()
                .map(|desktop| {
                    let kind = self.mapper.classify(desktop.cwd.clone());
                    let project_path = (kind == ConversationKind::Project)
                        .then(|| desktop.cwd.to_string_lossy().into_owned());
                    self.desktop_summary(desktop, kind, None, project_path)
                })
                .collect::<Vec<_>>();
            conversations.sort_by(|left, right| {
                right
                    .updated_at
                    .cmp(&left.updated_at)
                    .then_with(|| left.id.cmp(&right.id))
            });
            return Ok(conversations);
        }
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
        let mut known_cli_ids = session_paths.keys().cloned().collect::<HashSet<_>>();
        let mut desktop_sessions = HashMap::new();
        for desktop in collect_desktop_sessions(&self.mapper.home)? {
            if conversations
                .iter()
                .any(|conversation| conversation.id == desktop.desktop_id)
                || desktop
                    .cli_id
                    .as_ref()
                    .is_some_and(|cli_id| known_cli_ids.contains(cli_id))
            {
                continue;
            }
            if let Some(cli_id) = desktop.cli_id.as_ref() {
                known_cli_ids.insert(cli_id.clone());
            }
            let writable = desktop.cli_id.is_some();
            desktop_sessions.insert(
                desktop.desktop_id.clone(),
                DesktopSessionTarget {
                    cli_id: desktop.cli_id.clone(),
                    cwd: desktop.cwd.clone(),
                    user_selected_folders: desktop.user_selected_folders.clone(),
                    transcript_path: desktop.transcript_path.clone(),
                },
            );
            conversations.push(ConversationSummary {
                id: desktop.desktop_id,
                provider: ProviderId::Claude,
                kind: ConversationKind::Daily,
                title: desktop.title,
                project_id: None,
                project_path: None,
                updated_at: desktop.updated_at.max(desktop.created_at),
                status: "idle".into(),
                write_state: Some(if writable {
                    WriteState::Available
                } else {
                    WriteState::Unavailable
                }),
                write_block_code: (!writable).then(|| "claude_cli_session_unavailable".into()),
            });
        }
        conversations.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        *self.session_paths.write().await = session_paths;
        *self.desktop_sessions.write().await = desktop_sessions;
        Ok(conversations)
    }

    async fn list_daily_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        let desktop_sessions = self.refresh_desktop_index().await?;
        let mut conversations = desktop_sessions
            .iter()
            .map(|desktop| self.desktop_summary(desktop, ConversationKind::Daily, None, None))
            .collect::<Vec<_>>();
        conversations.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(conversations)
    }

    async fn list_projects(&self) -> anyhow::Result<Vec<crate::protocol::ProjectSummary>> {
        let desktop_sessions = self.refresh_desktop_index().await?;
        let mut projects = HashMap::new();
        for desktop in &desktop_sessions {
            let mut paths = vec![desktop.cwd.clone()];
            paths.extend(desktop.user_selected_folders.iter().cloned());
            for path in paths {
                let canonical_path = canonical_or_normalized(&path);
                let id = crate::catalog::project_id_for_path(
                    ProviderId::Claude,
                    &canonical_path,
                );
                let updated_at = desktop.updated_at.max(desktop.created_at);
                let display_path = display_path(&canonical_path, &self.mapper.home);
                let title = Path::new(&canonical_path)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(&display_path)
                    .to_owned();
                projects
                    .entry(canonical_path.clone())
                    .and_modify(|project: &mut crate::protocol::ProjectSummary| {
                        if updated_at > project.updated_at {
                            project.updated_at = updated_at;
                        }
                        project.available |= Path::new(&canonical_path).is_dir();
                    })
                    .or_insert(crate::protocol::ProjectSummary {
                        id,
                        provider: ProviderId::Claude,
                        canonical_path: canonical_path.clone(),
                        display_path,
                        title,
                        updated_at,
                        available: Path::new(&canonical_path).is_dir(),
                    });
            }
        }
        let mut projects = projects.into_values().collect::<Vec<_>>();
        projects.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(projects)
    }

    async fn list_project_conversations(
        &self,
        project_id: &str,
    ) -> anyhow::Result<Vec<ConversationSummary>> {
        let desktop_sessions = self.refresh_desktop_index().await?;
        let project = self
            .list_projects()
            .await?
            .into_iter()
            .find(|project| project.id == project_id);
        let Some(project) = project else {
            return Ok(Vec::new());
        };
        let mut conversations = Vec::new();
        for desktop in desktop_sessions {
            let mut paths = vec![desktop.cwd.clone()];
            paths.extend(desktop.user_selected_folders.iter().cloned());
            if paths
                .iter()
                .map(|path| canonical_or_normalized(path))
                .any(|path| path == project.canonical_path)
            {
                conversations.push(self.desktop_summary(
                    &desktop,
                    ConversationKind::Project,
                    Some(project.id.clone()),
                    Some(desktop.cwd.to_string_lossy().into_owned()),
                ));
            }
        }
        Ok(conversations)
    }

    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        let desktop = self.desktop_sessions.read().await.get(id).cloned();
        // A session started from the phone is addressed by its placeholder id
        // until a refresh; resolve it to the transcript Claude actually wrote.
        let resolved = self.resolved_session_id(id).await;
        let lookup = desktop
            .as_ref()
            .map(|_| id)
            .unwrap_or_else(|| resolved.as_deref().unwrap_or(id));
        let path = match desktop.as_ref() {
            Some(target) => target.transcript_path.clone(),
            None => self.session_paths.read().await.get(lookup).cloned(),
        };
        let Some(path) = path else {
            // A session this agent just started has no transcript on disk yet.
            // That is an empty history, not a failure — the phone opens the
            // screen before the first turn exists.
            anyhow::ensure!(
                desktop.is_some() || self.sessions.read().await.contains_key(id),
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
        if let Some(target) = self.desktop_sessions.read().await.get(id).cloned() {
            let cli_id = target
                .cli_id
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("desktop session has no CLI session id"))?;
            anyhow::ensure!(
                target.cwd.is_dir(),
                "desktop session directory is unavailable"
            );
            let session = self
                .spawn_session(Some(cli_id), Some(&target.cwd), id)
                .await?;
            self.sessions.write().await.insert(id.to_owned(), session);
            return Ok(());
        }
        // Only a session this agent knows may be resumed: an id from the phone
        // must never turn into a CLI spawned for an arbitrary string.
        anyhow::ensure!(
            self.session_paths.read().await.contains_key(id)
                || self.sessions.read().await.contains_key(id),
            "session is not indexed"
        );
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
        let existing = self.sessions.read().await.get(id).cloned();
        let session = match existing {
            Some(session) => session,
            None => {
                // The phone is writing to a conversation that already existed
                // on the Mac. Resuming it here is what the user asked for by
                // pressing send; the gateway has already checked that no other
                // writer holds it.
                self.resume(id).await?;
                self.sessions
                    .read()
                    .await
                    .get(id)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("session is not active"))?
            }
        };
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

fn canonical_or_normalized(path: &Path) -> String {
    if let Ok(canonical) = path.canonicalize() {
        return canonical.to_string_lossy().into_owned();
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized.to_string_lossy().into_owned()
}

fn display_path(path: &str, home: &Path) -> String {
    let path = Path::new(path);
    match path.strip_prefix(home) {
        Ok(relative) if relative.as_os_str().is_empty() => "~".to_owned(),
        Ok(relative) => format!("~/{}", relative.to_string_lossy()),
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

fn remap_event_session_id(event: ConversationEvent, public_id: &str) -> ConversationEvent {
    fn set_id(mut payload: Value, public_id: &str) -> Value {
        if let Some(object) = payload.as_object_mut() {
            object.insert("conversationId".into(), Value::String(public_id.into()));
            object.insert("sessionId".into(), Value::String(public_id.into()));
        }
        payload
    }
    match event {
        ConversationEvent::Started(payload) => {
            ConversationEvent::Started(set_id(payload, public_id))
        }
        ConversationEvent::ApprovalRequested(payload) => {
            ConversationEvent::ApprovalRequested(set_id(payload, public_id))
        }
        ConversationEvent::TurnCompleted(payload) => {
            ConversationEvent::TurnCompleted(set_id(payload, public_id))
        }
        ConversationEvent::TurnFailed(payload) => {
            ConversationEvent::TurnFailed(set_id(payload, public_id))
        }
        ConversationEvent::TurnInterrupted(payload) => {
            ConversationEvent::TurnInterrupted(set_id(payload, public_id))
        }
        other => other,
    }
}

fn collect_desktop_sessions(home: &Path) -> anyhow::Result<Vec<DesktopSessionMeta>> {
    let current_root = home
        .join("Library")
        .join("Application Support")
        .join("Claude")
        .join("claude-code-sessions");
    let root = if current_root.exists() {
        current_root
    } else {
        home.join("Library")
            .join("Application Support")
            .join("Claude")
            .join("local-agent-mode-sessions")
    };
    let mut metadata_paths = Vec::new();
    collect_desktop_metadata_paths(&root, 0, &mut metadata_paths)?;
    let mut sessions = Vec::new();
    for path in metadata_paths {
        if fs::metadata(&path)?.len() > MAX_METADATA_LINE_BYTES as u64 {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(&fs::read(&path)?) else {
            continue;
        };
        if value
            .get("isArchived")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        let Some(desktop_id) = value.get("sessionId").and_then(Value::as_str) else {
            continue;
        };
        let Some(title) = value.get("title").and_then(Value::as_str) else {
            continue;
        };
        let Some(cwd) = value.get("cwd").and_then(Value::as_str) else {
            continue;
        };
        if desktop_id.is_empty() || title.trim().is_empty() || cwd.is_empty() {
            continue;
        }
        let cli_id = value
            .get("cliSessionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        let transcript_path = cli_id
            .as_ref()
            .and_then(|cli_id| {
                find_cli_transcript(home, cli_id).or_else(|| {
                    path.parent()
                        .map(|parent| parent.join(format!("{cli_id}.jsonl")))
                        .filter(|candidate| candidate.is_file())
                })
            });
        let user_selected_folders = value
            .get("userSelectedFolders")
            .and_then(Value::as_array)
            .map(|folders| {
                folders
                    .iter()
                    .filter_map(Value::as_str)
                    .filter(|folder| !folder.is_empty())
                    .map(PathBuf::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        sessions.push(DesktopSessionMeta {
            desktop_id: desktop_id.to_owned(),
            cli_id,
            cwd: PathBuf::from(cwd),
            title: title.chars().take(512).collect(),
            created_at: desktop_timestamp(value.get("createdAt")),
            updated_at: desktop_timestamp(value.get("lastActivityAt")),
            user_selected_folders,
            transcript_path,
        });
    }
    Ok(sessions)
}

fn find_cli_transcript(home: &Path, cli_id: &str) -> Option<PathBuf> {
    let root = home.join(".claude/projects");
    let mut pending = vec![(root, 0_usize)];
    while let Some((directory, depth)) = pending.pop() {
        if depth > MAX_DESKTOP_DEPTH {
            continue;
        }
        let entries = fs::read_dir(directory).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            let file_type = entry.file_type().ok()?;
            if file_type.is_dir() {
                pending.push((path, depth + 1));
            } else if file_type.is_file()
                && path.extension().and_then(|ext| ext.to_str()) == Some("jsonl")
                && path.file_stem().and_then(|stem| stem.to_str()) == Some(cli_id)
            {
                return Some(path);
            }
        }
    }
    None
}

fn collect_desktop_metadata_paths(
    root: &Path,
    depth: usize,
    paths: &mut Vec<PathBuf>,
) -> anyhow::Result<()> {
    if depth > MAX_DESKTOP_DEPTH {
        return Ok(());
    }
    let Ok(entries) = fs::read_dir(root) else {
        return Ok(());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            collect_desktop_metadata_paths(&path, depth + 1, paths)?;
        } else if file_type.is_file()
            && path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with("local_")
                        && path.extension().and_then(|ext| ext.to_str()) == Some("json")
                })
        {
            paths.push(path);
        }
    }
    Ok(())
}

fn desktop_timestamp(value: Option<&Value>) -> DateTime<Utc> {
    value
        .and_then(Value::as_i64)
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .unwrap_or_else(|| DateTime::<Utc>::from(std::time::SystemTime::UNIX_EPOCH))
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
