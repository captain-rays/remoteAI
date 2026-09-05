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

use super::{ConversationPage, DEFAULT_HISTORY_TURNS, ProviderAdapter, history_turn_page};
use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProviderId,
    ProviderStatus, WriteState,
};

const MAX_METADATA_LINE_BYTES: usize = 64 * 1024;
/// Upper bound on how much of the CLI's own complaint is forwarded.
const MAX_STDERR_REPORT_CHARS: usize = 500;
/// Permission mode phone-started sessions run in.
///
/// This CLI cannot forward a permission prompt to a remote client: under
/// `manual` it answers "This command requires approval" and denies, with no
/// `control_request` for anyone to answer, so a phone could not run `git
/// fetch` at all. The product decision is that the phone is a convenience
/// client and runs unattended. `REMOTEAI_CLAUDE_PERMISSION_MODE` dials it back
/// without a rebuild — `manual` restores refusal, `auto` approves each request
/// but keeps the working-directory sandbox.
const DEFAULT_PERMISSION_MODE: &str = "bypassPermissions";
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
    /// Directory each indexed CLI session was recorded in. `--resume` only
    /// resolves a session id inside its own project directory, so a resume
    /// launched anywhere else exits with "No conversation found".
    session_cwds: RwLock<HashMap<String, PathBuf>>,
    /// Directory each session this agent started runs in. Kept separately from
    /// the index, which is replaced wholesale on every refresh.
    started_cwds: RwLock<HashMap<String, PathBuf>>,
    desktop_sessions: RwLock<HashMap<String, DesktopSessionTarget>>,
    /// Placeholder id handed to the phone -> the id Claude itself assigned.
    adopted_ids: Arc<RwLock<HashMap<String, String>>>,
    history_turns: usize,
    /// Model passed to the CLI. `None` leaves the Mac's own default in place;
    /// an operator sets it when that default is not usable for phone-started
    /// turns.
    model: Option<String>,
    permission_mode: String,
}

#[derive(Debug, Clone)]
struct DesktopSessionTarget {
    cli_id: Option<String>,
    cwd: PathBuf,
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

impl DesktopSessionMeta {
    /// Every directory this desktop session is associated with, canonicalized.
    fn project_paths(&self) -> impl Iterator<Item = String> + '_ {
        std::iter::once(&self.cwd)
            .chain(self.user_selected_folders.iter())
            .map(|path| canonical_or_normalized(path))
    }

    fn recency(&self) -> DateTime<Utc> {
        self.updated_at.max(self.created_at)
    }
}

/// One session indexed from `~/.claude/projects`.
#[derive(Debug, Clone)]
struct CliSession {
    summary: ConversationSummary,
    /// Directory the session ran in.
    cwd: String,
    /// The designated project that encloses `cwd`, if any. A session in a
    /// worktree or a subdirectory belongs to the project above it; one that no
    /// project encloses has no project view and lives in Chats.
    project: Option<String>,
}

/// A single read of everything Claude records locally: the desktop app's
/// session metadata and the CLI's own project transcripts. Both are indexes,
/// never copies of transcript bodies or credentials.
struct ClaudeIndex {
    desktop: Vec<DesktopSessionMeta>,
    /// CLI sessions the desktop catalog does not already represent.
    cli: Vec<CliSession>,
}

impl ClaudeIndex {
    /// Each project directory with its recency.
    fn project_paths(&self) -> Vec<(String, DateTime<Utc>)> {
        let mut paths = Vec::new();
        for desktop in &self.desktop {
            let recency = desktop.recency();
            paths.extend(desktop.project_paths().map(|path| (path, recency)));
        }
        // A session's own directory only becomes a project when it has a
        // project to belong to; otherwise every worktree and temporary
        // directory a session ran in would show up as its own project.
        for session in &self.cli {
            if let Some(path) = session.project.clone() {
                paths.push((path, session.summary.updated_at));
            }
        }
        paths
    }
}

/// Whether `path` is `parent` or sits underneath it.
fn is_within(path: &str, parent: &str) -> bool {
    let path = Path::new(path);
    let parent = Path::new(parent);
    path == parent || path.starts_with(parent)
}

/// The project that encloses `cwd`, preferring the closest one when projects
/// nest.
fn enclosing_project(cwd: &str, projects: &[String]) -> Option<String> {
    projects
        .iter()
        .filter(|candidate| is_within(cwd, candidate))
        .max_by_key(|candidate| Path::new(candidate).components().count())
        .cloned()
}

/// The directories that are Claude projects on this Mac.
///
/// A directory the user designated in the desktop app — its `cwd` or one of
/// its selected folders — is always a project, however it nests. A directory
/// only the CLI has seen becomes one too, so a project worked on from the
/// terminal is not invisible, but only when it is inside the paired user's
/// HOME and no other project already covers it. Without that last rule every
/// worktree, subdirectory and temporary directory a session happened to run in
/// showed up as a project of its own.
fn project_directories(
    home: &str,
    desktop: &[DesktopSessionMeta],
    cli: &[CliSession],
) -> Vec<String> {
    let mut designated = desktop
        .iter()
        .flat_map(DesktopSessionMeta::project_paths)
        .filter(|path| path != home)
        .collect::<Vec<_>>();
    designated.sort_unstable();
    designated.dedup();

    let mut candidates = cli
        .iter()
        .map(|session| session.cwd.clone())
        .filter(|path| path != home && is_within(path, home))
        .filter(|path| {
            !designated
                .iter()
                .any(|project| is_within(path, project) && path != project)
        })
        .collect::<Vec<_>>();
    candidates.sort_unstable();
    candidates.dedup();
    // Among the CLI's own directories, the outermost one wins: a session in a
    // subdirectory of another session's directory belongs to it.
    let nested = candidates
        .iter()
        .filter(|path| {
            candidates
                .iter()
                .any(|other| other != *path && is_within(path, other))
        })
        .cloned()
        .collect::<HashSet<_>>();

    let mut projects = designated;
    let known = projects.iter().cloned().collect::<HashSet<_>>();
    projects.extend(
        candidates
            .into_iter()
            .filter(|path| !nested.contains(path) && !known.contains(path)),
    );
    projects
}

fn sort_by_recency(conversations: &mut [ConversationSummary]) {
    conversations.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
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
            session_cwds: RwLock::new(HashMap::new()),
            started_cwds: RwLock::new(HashMap::new()),
            desktop_sessions: RwLock::new(HashMap::new()),
            adopted_ids: Arc::new(RwLock::new(HashMap::new())),
            history_turns: DEFAULT_HISTORY_TURNS,
            model: None,
            permission_mode: DEFAULT_PERMISSION_MODE.to_owned(),
        }
    }

    /// Run sessions in a different permission mode than the default.
    pub fn with_permission_mode(mut self, mode: Option<String>) -> Self {
        if let Some(mode) = mode.map(|mode| mode.trim().to_owned())
            && !mode.is_empty()
        {
            self.permission_mode = mode;
        }
        self
    }

    /// Run every session this adapter starts on an explicit model.
    ///
    /// The CLI otherwise inherits the Mac's configured default, which can be a
    /// model the account cannot actually use — the turn then fails with the
    /// provider's own credit error and the phone gets no answer.
    pub fn with_model(mut self, model: Option<String>) -> Self {
        self.model = model.filter(|model| !model.trim().is_empty());
        self
    }

    /// The id Claude assigned to a session this agent started, once its first
    /// record arrives. Until then the placeholder is all anyone has.
    pub async fn resolved_session_id(&self, id: &str) -> Option<String> {
        self.adopted_ids.read().await.get(id).cloned()
    }

    /// Narrow the page to fewer turns. Tests use it to exercise paging on
    /// small fixtures; production keeps the default.
    pub fn with_history_turns(mut self, turns: usize) -> Self {
        self.history_turns = turns.max(1);
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
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        args.extend(["--permission-mode".to_owned(), self.permission_mode.clone()]);
        if let Some(model) = self.model.as_deref() {
            args.extend(["--model".into(), model.into()]);
        }
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
        // Keep the CLI's own complaint. A session that dies on startup —
        // "No conversation found with session ID", a bad flag — otherwise
        // produces no stdout at all, and the phone is left with a message it
        // sent and no answer and no reason.
        let stderr_tail = Arc::new(Mutex::new(String::new()));
        if let Some(stderr) = child.stderr.take() {
            let tail = stderr_tail.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line.trim().is_empty() {
                        continue;
                    }
                    let mut tail = tail.lock().await;
                    // Bounded: only the last complaint is worth reporting.
                    *tail = line.chars().take(MAX_STDERR_REPORT_CHARS).collect();
                }
            });
        }
        let events = self.events.clone();
        let mapper = self.mapper.clone();
        let adopted = self.adopted_ids.clone();
        let local_id = local_id.to_owned();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut reported_anything = false;
            while let Ok(Some(line)) = lines.next_line().await {
                if let Some(real) = session_id_from_init(&line)
                    && real != local_id
                {
                    adopted.write().await.insert(local_id.clone(), real);
                }
                if let Ok(value) = mapper.map_line_for_session(&line, &local_id) {
                    reported_anything = true;
                    let _ = events.send(value);
                }
            }
            // The CLI is gone. If it never said anything, say why on its
            // behalf rather than leaving the turn unanswered forever.
            if !reported_anything {
                let reason = stderr_tail.lock().await.clone();
                let reason = if reason.is_empty() {
                    "the Claude CLI exited without producing any output".to_owned()
                } else {
                    reason
                };
                eprintln!("claude session {local_id} produced no output: {reason}");
                let _ = events.send(ConversationEvent::TurnFailed(json!({
                    "conversationId": local_id,
                    "code": "cli_produced_no_output",
                    "message": reason,
                })));
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

    /// Read both local Claude indexes in one pass and publish the lookup maps
    /// the write and history paths depend on.
    ///
    /// The desktop catalog and the CLI's own `~/.claude/projects` index are
    /// separate views of the same machine. Reading only one of them — which is
    /// what returning early on the desktop root did — leaves every session the
    /// other view owns unlistable, and therefore unwritable, because nothing
    /// can resolve its transcript.
    async fn refresh_index(&self) -> anyhow::Result<ClaudeIndex> {
        let desktop = collect_desktop_sessions(&self.mapper.home)?;
        let mut targets = HashMap::new();
        let mut wrapped_cli_ids = HashSet::new();
        for session in &desktop {
            if let Some(cli_id) = session.cli_id.as_ref() {
                wrapped_cli_ids.insert(cli_id.clone());
            }
            targets.insert(
                session.desktop_id.clone(),
                DesktopSessionTarget {
                    cli_id: session.cli_id.clone(),
                    cwd: session.cwd.clone(),
                    transcript_path: session.transcript_path.clone(),
                },
            );
        }

        let mut session_paths = HashMap::new();
        let mut session_cwds = HashMap::new();
        let mut cli = Vec::new();
        let mut pending = vec![self.mapper.home.join(".claude/projects")];
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
                    continue;
                }
                if !file_type.is_file()
                    || path.extension().and_then(|extension| extension.to_str()) != Some("jsonl")
                {
                    continue;
                }
                let Some(summary) = read_conversation_metadata(&self.mapper, &path)? else {
                    continue;
                };
                session_paths
                    .entry(summary.id.clone())
                    .or_insert_with(|| path.clone());
                session_cwds
                    .entry(summary.id.clone())
                    .or_insert_with(|| session_cwd(&self.mapper, &path));
                // The desktop app addresses this session by its own id, and
                // that entry carries the title the user chose. Listing the CLI
                // record too would show the same conversation twice.
                if wrapped_cli_ids.contains(&summary.id) {
                    continue;
                }
                let cwd = summary
                    .project_path
                    .as_deref()
                    .map(|path| canonical_or_normalized(Path::new(path)))
                    .unwrap_or_else(|| canonical_or_normalized(&self.mapper.home));
                cli.push(CliSession {
                    summary,
                    cwd,
                    project: None,
                });
            }
        }

        let home = canonical_or_normalized(&self.mapper.home);
        let projects = project_directories(&home, &desktop, &cli);
        for session in &mut cli {
            session.project = enclosing_project(&session.cwd, &projects);
        }

        *self.desktop_sessions.write().await = targets;
        *self.session_paths.write().await = session_paths;
        *self.session_cwds.write().await = session_cwds;
        Ok(ClaudeIndex { desktop, cli })
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
            updated_at: desktop.recency(),
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
        let index = self.refresh_index().await?;
        let mut conversations = index
            .desktop
            .iter()
            .map(|desktop| self.desktop_summary(desktop, ConversationKind::Daily, None, None))
            .collect::<Vec<_>>();
        conversations.extend(index.cli.iter().map(|session| session.summary.clone()));
        sort_by_recency(&mut conversations);
        Ok(conversations)
    }

    async fn list_daily_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        let index = self.refresh_index().await?;
        let mut conversations = index
            .desktop
            .iter()
            .map(|desktop| self.desktop_summary(desktop, ConversationKind::Daily, None, None))
            .collect::<Vec<_>>();
        // A CLI session no project encloses has no project view to appear in,
        // so Chats is the only place it can be reached from. One that does
        // belong to a project is listed there instead of crowding this list.
        conversations.extend(
            index
                .cli
                .iter()
                .filter(|session| session.project.is_none())
                .map(|session| {
                    let mut summary = session.summary.clone();
                    summary.kind = ConversationKind::Daily;
                    summary.project_id = None;
                    summary.project_path = None;
                    summary
                }),
        );
        sort_by_recency(&mut conversations);
        Ok(conversations)
    }

    async fn list_projects(&self) -> anyhow::Result<Vec<crate::protocol::ProjectSummary>> {
        let index = self.refresh_index().await?;
        let mut projects = HashMap::new();
        for (canonical_path, updated_at) in index.project_paths() {
            let display_path = display_path(&canonical_path, &self.mapper.home);
            let title = Path::new(&canonical_path)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or(&display_path)
                .to_owned();
            let available = Path::new(&canonical_path).is_dir();
            projects
                .entry(canonical_path.clone())
                .and_modify(|project: &mut crate::protocol::ProjectSummary| {
                    if updated_at > project.updated_at {
                        project.updated_at = updated_at;
                    }
                    project.available |= available;
                })
                .or_insert(crate::protocol::ProjectSummary {
                    id: crate::catalog::project_id_for_path(ProviderId::Claude, &canonical_path),
                    provider: ProviderId::Claude,
                    canonical_path: canonical_path.clone(),
                    display_path,
                    title,
                    updated_at,
                    available,
                });
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
        let index = self.refresh_index().await?;
        let project = self
            .list_projects()
            .await?
            .into_iter()
            .find(|project| project.id == project_id);
        let Some(project) = project else {
            return Ok(Vec::new());
        };
        let mut conversations = Vec::new();
        for desktop in &index.desktop {
            if desktop
                .project_paths()
                .any(|path| path == project.canonical_path)
            {
                conversations.push(self.desktop_summary(
                    desktop,
                    ConversationKind::Project,
                    Some(project.id.clone()),
                    Some(project.canonical_path.clone()),
                ));
            }
        }
        for session in &index.cli {
            if session.project.as_deref() == Some(project.canonical_path.as_str()) {
                let mut summary = session.summary.clone();
                summary.kind = ConversationKind::Project;
                summary.project_id = Some(project.id.clone());
                summary.project_path = Some(project.canonical_path.clone());
                conversations.push(summary);
            }
        }
        sort_by_recency(&mut conversations);
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
        let turns = group_into_turns(read_conversation_events(lookup, &path)?);
        let (range, next_cursor) =
            history_turn_page(turns.len(), cursor.as_deref(), self.history_turns)?;
        Ok(ConversationPage {
            conversation_id: id.to_owned(),
            events: turns[range].concat(),
            next_cursor,
        })
    }

    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        // Claude files a session under the directory its process runs in, and
        // that directory is what makes the session a chat or a project session.
        // Without an explicit one, a chat has to run in the paired user's HOME
        // — inheriting the agent's own working directory filed phone-started
        // chats as sessions of whatever project the agent was launched from.
        let cwd = match kind {
            ConversationKind::Daily => cwd.or_else(|| Some(self.mapper.home.clone())),
            ConversationKind::Project => cwd,
        };
        if let Some(cwd) = cwd.as_deref() {
            anyhow::ensure!(cwd.is_dir(), "project directory is not available");
        }
        let id = format!("pending-{}", uuid::Uuid::new_v4());
        let session = self.spawn_session(None, cwd.as_deref(), &id).await?;
        if let Some(cwd) = cwd {
            self.started_cwds.write().await.insert(id.clone(), cwd);
        }
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
        // A session this agent started is addressed by its placeholder until a
        // refresh; the CLI only knows the id it assigned itself.
        let cli_id = self
            .resolved_session_id(id)
            .await
            .unwrap_or_else(|| id.to_owned());
        let known = |paths: &HashMap<String, PathBuf>| {
            paths.contains_key(id) || paths.contains_key(&cli_id)
        };
        if !known(&*self.session_paths.read().await) {
            // The index may predate this session, so read it once more before
            // refusing.
            let _ = self.refresh_index().await;
        }
        // Only a session this agent knows may be resumed: an id from the phone
        // must never turn into a CLI spawned for an arbitrary string.
        anyhow::ensure!(
            known(&*self.session_paths.read().await) || self.sessions.read().await.contains_key(id),
            "session is not indexed"
        );
        // `--resume` resolves a session id only inside the directory the
        // session was recorded in: run it anywhere else and the CLI exits with
        // "No conversation found with session ID". Resuming there also keeps
        // the new turns in the same transcript as the rest of the session.
        let cwds = self.session_cwds.read().await;
        let cwd = cwds
            .get(&cli_id)
            .or_else(|| cwds.get(id))
            .cloned()
            .or_else(|| Some(self.mapper.home.clone()))
            .filter(|path| path.is_dir());
        drop(cwds);
        // The phone keeps addressing the session by the id it was given, so
        // the events stay labelled with that id.
        let session = self
            .spawn_session(Some(&cli_id), cwd.as_deref(), id)
            .await?;
        self.sessions.write().await.insert(id.to_owned(), session);
        Ok(())
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
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
        let payload = json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": content}]
            }
        });
        // A writer this agent already holds is tried first. If the CLI behind
        // it has gone away the write fails with a broken pipe, and keeping the
        // dead handle would fail every later message too — so it is dropped
        // and the session is resumed once.
        // Bind the handle in its own statement: a guard created inside an
        // `if let` scrutinee is held for the whole block, and the write below
        // needs the same lock.
        let held = self.sessions.read().await.get(id).cloned();
        if let Some(session) = held {
            match Self::write(&session, payload.clone()).await {
                Ok(()) => return Ok(()),
                Err(_) => {
                    self.sessions.write().await.remove(id);
                }
            }
        }
        // The phone is writing to a conversation that already existed on the
        // Mac, or to one whose CLI died. Resuming it here is what the user
        // asked for by pressing send; the gateway has already checked that no
        // other writer holds it.
        if let Err(error) = self.resume(id).await {
            // There is nothing to resume: a session this agent started can
            // crash before it writes its first record. Opening a fresh writer
            // in the same directory loses no history and keeps the id the
            // phone is using, where refusing would fail every later message.
            let cwd = self
                .started_cwds
                .read()
                .await
                .get(id)
                .cloned()
                .filter(|path| path.is_dir());
            let Some(cwd) = cwd else { return Err(error) };
            let session = self.spawn_session(None, Some(&cwd), id).await?;
            self.sessions.write().await.insert(id.to_owned(), session);
        }
        let session = self
            .sessions
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("session is not active"))?;
        Self::write(&session, payload).await
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
        let transcript_path = cli_id.as_ref().and_then(|cli_id| {
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

/// The directory a CLI session was recorded in. The transcript states it; the
/// enclosing `~/.claude/projects/<slug>` directory is a lossy encoding of the
/// same path, so the transcript wins and HOME is the fallback.
fn session_cwd(mapper: &ClaudeMapper, transcript: &Path) -> PathBuf {
    let Ok(file) = File::open(transcript) else {
        return mapper.home.clone();
    };
    for line in StdBufReader::new(file).lines() {
        let Ok(line) = line else { continue };
        if line.len() > MAX_METADATA_LINE_BYTES {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(cwd) = string_field(&value, &["cwd"]) {
            return PathBuf::from(cwd);
        }
    }
    mapper.home.clone()
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

/// Split a normalized transcript into turns.
///
/// A turn starts at each user message. Claude records a tool result as a
/// `user` line too, but normalization already turns those into `tool.completed`
/// — so a `conversation.user_message` really is the start of a new exchange.
/// Anything before the first one is bookkeeping that belongs to the oldest
/// page rather than to no page at all.
fn group_into_turns(events: Vec<Value>) -> Vec<Vec<Value>> {
    let mut turns: Vec<Vec<Value>> = Vec::new();
    for event in events {
        let starts_turn =
            event.get("type").and_then(Value::as_str) == Some("conversation.user_message");
        if starts_turn || turns.is_empty() {
            turns.push(Vec::new());
        }
        turns
            .last_mut()
            .expect("a turn was just pushed")
            .push(event);
    }
    turns
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
