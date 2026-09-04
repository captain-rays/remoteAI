use std::path::PathBuf;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ConversationSummary, ProjectSummary,
    ProviderStatus, WriteState,
};

pub mod claude;
pub mod codex;
pub mod mock;

/// Turns carried by one history page.
///
/// A page is measured in turns rather than records because the phone opens on
/// the newest turn and pages backwards: a turn read on its own is a complete
/// exchange, where a fixed number of records can cut one in half.
pub const DEFAULT_HISTORY_TURNS: usize = 5;

/// The range of turns one history page covers, newest page first, plus the
/// cursor for the page before it.
///
/// The cursor counts the *oldest* turns still undelivered. Measuring from that
/// end keeps it valid while the phone pages backwards through a conversation
/// that is still being appended to — a cursor counted from the newest end
/// would shift under every live turn and deliver the same one twice.
pub fn history_turn_page(
    total_turns: usize,
    cursor: Option<&str>,
    turns_per_page: usize,
) -> anyhow::Result<(std::ops::Range<usize>, Option<String>)> {
    let end = match cursor {
        Some(cursor) => cursor
            .parse::<usize>()
            .map_err(|_| anyhow::anyhow!("invalid history cursor"))?,
        None => total_turns,
    };
    anyhow::ensure!(end <= total_turns, "history cursor is out of range");
    let start = end.saturating_sub(turns_per_page.max(1));
    Ok((start..end, (start > 0).then(|| start.to_string())))
}

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
    /// List the provider's global Chats view. This is intentionally separate
    /// from the generic session index because some providers have a host-owned
    /// chat catalog that cannot be inferred from local CLI sessions.
    async fn list_daily_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
        Ok(self
            .list_conversations()
            .await?
            .into_iter()
            .filter(|conversation| conversation.kind == ConversationKind::Daily)
            .collect())
    }

    /// Stable diagnostic for an unavailable global Chats view. An empty list
    /// without a diagnostic is a valid empty catalog; callers can distinguish
    /// it from an unavailable host bridge with this code.
    fn daily_catalog_diagnostic_code(&self) -> Option<&'static str> {
        None
    }

    /// List provider-native projects when available. Providers without a
    /// separate project index may return an empty list and let the gateway
    /// derive projects from conversation metadata.
    async fn list_projects(&self) -> anyhow::Result<Vec<ProjectSummary>> {
        Ok(Vec::new())
    }
    async fn list_project_conversations(
        &self,
        project_id: &str,
    ) -> anyhow::Result<Vec<ConversationSummary>> {
        Ok(self
            .list_conversations()
            .await?
            .into_iter()
            .filter(|conversation| conversation.project_id.as_deref() == Some(project_id))
            .collect())
    }
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
    /// Return the current write lease state for a conversation. Providers may
    /// conservatively report `Busy` when external activity cannot be proven
    /// absent. Read-only list/history calls remain available in all states.
    async fn write_availability(&self, id: &str) -> anyhow::Result<WriteState> {
        if !self.status().await.available {
            return Ok(WriteState::Unavailable);
        }
        Ok(self
            .list_conversations()
            .await?
            .into_iter()
            .find(|summary| summary.id == id)
            .and_then(|summary| summary.write_state)
            .unwrap_or(WriteState::Available))
    }
    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent>;
}
