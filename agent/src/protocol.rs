use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderId {
    Codex,
    Claude,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationKind {
    Daily,
    Project,
}

/// Which of a provider's two front ends recorded a conversation.
///
/// The phone lists everything on the Mac, and the desktop app only lists its
/// own — so most of what the phone shows for a project is invisible there.
/// Saying where a conversation came from is what makes that difference legible
/// rather than alarming.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationSource {
    /// Recorded by the provider's desktop application.
    Desktop,
    /// Recorded by the command-line tool.
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WriteState {
    Available,
    Busy,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    AllowOnce,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStatus {
    pub provider: ProviderId,
    pub available: bool,
    pub executable_path: Option<String>,
    pub version: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSummary {
    pub id: String,
    pub provider: ProviderId,
    pub kind: ConversationKind,
    pub title: String,
    pub project_id: Option<String>,
    pub project_path: Option<String>,
    pub updated_at: DateTime<Utc>,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_state: Option<WriteState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_block_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<ConversationSource>,
    /// The directory the conversation actually ran in, when that is not the
    /// project's own directory — a git worktree or a subdirectory belongs to
    /// the project above it, but the reader should still be able to tell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSummary {
    pub id: String,
    pub provider: ProviderId,
    pub canonical_path: String,
    pub display_path: String,
    pub title: String,
    pub updated_at: DateTime<Utc>,
    pub available: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Catalog {
    pub projects: Vec<ProjectSummary>,
    pub conversations: Vec<ConversationSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalRequest {
    pub id: String,
    pub provider: ProviderId,
    pub conversation_id: String,
    pub category: String,
    pub title: String,
    pub detail: String,
    pub cwd: Option<String>,
    pub risk: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileKind {
    File,
    Directory,
    Symlink,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub kind: FileKind,
    pub size: Option<u64>,
    pub modified_at: Option<DateTime<Utc>>,
    pub hidden: bool,
    pub readable: bool,
    pub sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnvelopeKind {
    Request,
    Response,
    Event,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestEnvelope {
    pub protocol_version: u16,
    pub message_id: Uuid,
    pub kind: EnvelopeKind,
    pub request_id: Option<Uuid>,
    #[serde(rename = "type")]
    pub message_type: String,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResponseEnvelope {
    pub protocol_version: u16,
    pub message_id: Uuid,
    pub kind: EnvelopeKind,
    pub request_id: Uuid,
    #[serde(rename = "type")]
    pub message_type: String,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConversationEvent {
    Delta { text: String },
    Started(Value),
    UserMessage(Value),
    MessageCompleted(Value),
    ReasoningDelta(Value),
    ReasoningCompleted(Value),
    ToolStarted(Value),
    ToolUpdated(Value),
    ToolCompleted(Value),
    ApprovalRequested(Value),
    ApprovalResolved(Value),
    TurnCompleted(Value),
    TurnFailed(Value),
    TurnInterrupted(Value),
    ProviderStatusChanged(Value),
    Unsupported { raw_type: String, payload: Value },
}

#[derive(Debug, Clone, PartialEq)]
pub struct EventEnvelope {
    pub protocol_version: u16,
    pub message_id: Uuid,
    pub kind: EnvelopeKind,
    pub request_id: Option<Uuid>,
    pub sequence: u64,
    pub conversation_id: String,
    pub event: ConversationEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEventEnvelope {
    protocol_version: u16,
    message_id: Uuid,
    kind: EnvelopeKind,
    request_id: Option<Uuid>,
    sequence: u64,
    conversation_id: String,
    #[serde(rename = "type")]
    message_type: String,
    payload: Value,
}

impl<'de> Deserialize<'de> for EventEnvelope {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawEventEnvelope::deserialize(deserializer)?;
        let event = match raw.message_type.as_str() {
            "conversation.delta" => ConversationEvent::Delta {
                text: raw
                    .payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            },
            "conversation.started" => ConversationEvent::Started(raw.payload),
            "conversation.user_message" => ConversationEvent::UserMessage(raw.payload),
            "conversation.message_completed" => ConversationEvent::MessageCompleted(raw.payload),
            "conversation.reasoning_delta" => ConversationEvent::ReasoningDelta(raw.payload),
            "conversation.reasoning_completed" => {
                ConversationEvent::ReasoningCompleted(raw.payload)
            }
            "tool.started" => ConversationEvent::ToolStarted(raw.payload),
            "tool.updated" => ConversationEvent::ToolUpdated(raw.payload),
            "tool.completed" => ConversationEvent::ToolCompleted(raw.payload),
            "approval.requested" => ConversationEvent::ApprovalRequested(raw.payload),
            "approval.resolved" => ConversationEvent::ApprovalResolved(raw.payload),
            "turn.completed" => ConversationEvent::TurnCompleted(raw.payload),
            "turn.failed" => ConversationEvent::TurnFailed(raw.payload),
            "turn.interrupted" => ConversationEvent::TurnInterrupted(raw.payload),
            "provider.status_changed" => ConversationEvent::ProviderStatusChanged(raw.payload),
            _ => ConversationEvent::Unsupported {
                raw_type: raw.message_type,
                payload: raw.payload,
            },
        };
        Ok(Self {
            protocol_version: raw.protocol_version,
            message_id: raw.message_id,
            kind: raw.kind,
            request_id: raw.request_id,
            sequence: raw.sequence,
            conversation_id: raw.conversation_id,
            event,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum ProtocolError {
    #[error("protocol version {received} is unsupported; supported major is {supported}")]
    UpgradeRequired { supported: u16, received: u16 },
}

pub fn validate_protocol_version(received: u16) -> Result<(), ProtocolError> {
    if received == PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(ProtocolError::UpgradeRequired {
            supported: PROTOCOL_VERSION,
            received,
        })
    }
}
