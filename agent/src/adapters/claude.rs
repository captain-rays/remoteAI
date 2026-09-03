use std::collections::HashMap;
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
        }
    }

    pub fn command_spec(&self, resume: Option<&str>) -> CommandSpec {
        let mut args = vec![
            "--print",
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

    async fn spawn_session(&self, resume: Option<&str>) -> anyhow::Result<Arc<ClaudeSession>> {
        let spec = self.command_spec(resume);
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
        let events = self.events.clone();
        let mapper = self.mapper.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
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
        Ok(Vec::new())
    }

    async fn load_conversation(
        &self,
        id: &str,
        _cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        anyhow::ensure!(
            self.sessions.read().await.contains_key(id),
            "session is not active"
        );
        Ok(ConversationPage {
            conversation_id: id.to_owned(),
            events: Vec::new(),
            next_cursor: None,
        })
    }

    async fn start(&self, _kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        let session = self.spawn_session(None).await?;
        let id = format!("pending-{}", uuid::Uuid::new_v4());
        self.sessions
            .write()
            .await
            .insert(id.clone(), session.clone());
        if let Some(cwd) = cwd {
            Self::write(
                &session,
                json!({"type":"user","cwd":cwd,"message":{"role":"user","content":""}}),
            )
            .await?;
        }
        Ok(id)
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        let session = self.spawn_session(Some(id)).await?;
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

#[allow(dead_code)]
fn _metadata_time(value: Option<&Value>) -> DateTime<Utc> {
    value
        .and_then(Value::as_str)
        .and_then(|raw| DateTime::parse_from_rfc3339(raw).ok())
        .map(|time| time.with_timezone(&Utc))
        .unwrap_or_else(Utc::now)
}
