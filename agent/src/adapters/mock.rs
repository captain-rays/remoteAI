use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use chrono::Utc;
use serde_json::{Value, json};
use tokio::sync::{RwLock, broadcast};

use super::{ConversationPage, ProviderAdapter};
use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProviderId,
    ProviderStatus, WriteState,
};

pub struct MockAdapter {
    provider: ProviderId,
    next_id: AtomicU64,
    conversations: RwLock<HashMap<String, ConversationSummary>>,
    histories: RwLock<HashMap<String, Vec<Value>>>,
    busy: RwLock<HashSet<String>>,
    events: broadcast::Sender<ConversationEvent>,
}

impl MockAdapter {
    pub fn new(provider: ProviderId) -> Self {
        let (events, _) = broadcast::channel(64);
        Self {
            provider,
            next_id: AtomicU64::new(1),
            conversations: RwLock::new(HashMap::new()),
            histories: RwLock::new(HashMap::new()),
            busy: RwLock::new(HashSet::new()),
            events,
        }
    }

    fn emit(&self, event: ConversationEvent) {
        let _ = self.events.send(event);
    }

    pub fn emit_event(&self, event: ConversationEvent) {
        self.emit(event);
    }

    pub async fn set_busy(&self, id: &str, busy: bool) {
        let mut states = self.busy.write().await;
        if busy {
            states.insert(id.to_owned());
        } else {
            states.remove(id);
        }
        if let Some(summary) = self.conversations.write().await.get_mut(id) {
            summary.write_state = Some(if busy {
                WriteState::Busy
            } else {
                WriteState::Available
            });
            summary.write_block_code = busy.then(|| "session_busy".to_owned());
        }
    }

    pub async fn set_history(&self, id: &str, events: Vec<Value>) {
        self.histories.write().await.insert(id.to_owned(), events);
    }
}

#[async_trait]
impl ProviderAdapter for MockAdapter {
    async fn status(&self) -> ProviderStatus {
        ProviderStatus {
            provider: self.provider,
            available: true,
            executable_path: Some("mock".into()),
            version: Some("1.0.0".into()),
            reason: None,
        }
    }

    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        Ok(self.conversations.read().await.values().cloned().collect())
    }

    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        anyhow::ensure!(
            self.conversations.read().await.contains_key(id),
            "unknown conversation"
        );
        let start = cursor
            .as_deref()
            .map(str::parse::<usize>)
            .transpose()?
            .unwrap_or(0);
        let history = self
            .histories
            .read()
            .await
            .get(id)
            .cloned()
            .unwrap_or_default();
        anyhow::ensure!(start <= history.len(), "history cursor out of range");
        let end = (start + 1).min(history.len());
        Ok(ConversationPage {
            conversation_id: id.to_owned(),
            events: history[start..end].to_vec(),
            next_cursor: (end < history.len()).then(|| end.to_string()),
        })
    }

    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        let id = format!(
            "{}-mock-{}",
            match self.provider {
                ProviderId::Codex => "codex",
                ProviderId::Claude => "claude",
            },
            self.next_id.fetch_add(1, Ordering::Relaxed)
        );
        let project_path = cwd.map(|path| path.to_string_lossy().into_owned());
        let project_id = project_path
            .as_ref()
            .map(|path| format!("{:?}:{path}", self.provider).to_lowercase());
        self.conversations.write().await.insert(
            id.clone(),
            ConversationSummary {
                id: id.clone(),
                provider: self.provider,
                kind,
                title: "Mock conversation".into(),
                project_id,
                project_path,
                updated_at: Utc::now(),
                status: "idle".into(),
                write_state: None,
                write_block_code: None,
            },
        );
        self.emit(ConversationEvent::Started(json!({"conversationId": id})));
        Ok(id)
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.conversations.read().await.contains_key(id),
            "unknown conversation"
        );
        Ok(())
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.conversations.read().await.contains_key(id),
            "unknown conversation"
        );
        self.emit(ConversationEvent::Delta { text });
        self.emit(ConversationEvent::ToolStarted(json!({
            "conversationId": id,
            "tool": "read_attachment",
            "attachments": attachments,
        })));
        self.emit(ConversationEvent::ApprovalRequested(json!({
            "id": "approval-1",
            "conversationId": id,
            "decisionOptions": ["allow_once", "deny"]
        })));
        self.emit(ConversationEvent::TurnCompleted(
            json!({"conversationId": id}),
        ));
        Ok(())
    }

    async fn decide_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> anyhow::Result<()> {
        self.emit(ConversationEvent::ApprovalResolved(json!({
            "id": request_id,
            "decision": decision,
        })));
        Ok(())
    }

    async fn interrupt(&self, id: &str) -> anyhow::Result<()> {
        self.emit(ConversationEvent::TurnInterrupted(
            json!({"conversationId": id}),
        ));
        Ok(())
    }

    async fn write_availability(&self, id: &str) -> anyhow::Result<WriteState> {
        anyhow::ensure!(
            self.conversations.read().await.contains_key(id),
            "unknown conversation"
        );
        Ok(if self.busy.read().await.contains(id) {
            WriteState::Busy
        } else {
            WriteState::Available
        })
    }

    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent> {
        self.events.subscribe()
    }
}
