use std::path::PathBuf;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProviderStatus,
};

pub mod codex;
pub mod mock;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationPage {
    pub conversation_id: String,
    pub events: Vec<serde_json::Value>,
    pub next_cursor: Option<String>,
}

#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    async fn status(&self) -> ProviderStatus;
    async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>>;
    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage>;
    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String>;
    async fn resume(&self, id: &str) -> anyhow::Result<()>;
    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()>;
    async fn decide_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> anyhow::Result<()>;
    async fn interrupt(&self, id: &str) -> anyhow::Result<()>;
    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent>;
}
