use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, RwLock, broadcast, oneshot};

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
        let result = self
            .client()
            .await?
            .call("thread/list", json!({"sortDirection":"desc"}))
            .await?;
        self.mapper.map_thread_list_value(&result)
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
        let events = result
            .pointer("/thread/turns")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        Ok(ConversationPage {
            conversation_id: id.to_owned(),
            events,
            next_cursor: None,
        })
    }

    async fn start(&self, _kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
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
        required_string(result.get("thread").unwrap_or(&result), "id")
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
        let result = self
            .client()
            .await?
            .call("turn/start", json!({"threadId": id, "input": input}))
            .await?;
        if let Some(turn_id) = result.pointer("/turn/id").and_then(Value::as_str) {
            self.active_turns
                .write()
                .await
                .insert(id.to_owned(), turn_id.to_owned());
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
