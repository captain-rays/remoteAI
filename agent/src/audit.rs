use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::protocol::ProviderId;

#[derive(Debug, Clone)]
pub struct AuditRecord {
    pub device_id: String,
    pub provider: Option<ProviderId>,
    pub conversation_id: Option<String>,
    pub action: String,
    pub target_path: Option<String>,
    pub result: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuditRow {
    pub timestamp: DateTime<Utc>,
    pub device_id: String,
    pub provider: Option<ProviderId>,
    pub conversation_id: Option<String>,
    pub action: String,
    pub target_path: Option<String>,
    pub result: String,
}

#[derive(Clone, Default)]
pub struct AuditLog {
    rows: Arc<Mutex<Vec<AuditRow>>>,
}

impl AuditLog {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(&self, record: AuditRecord) {
        let result = redact(&record.result);
        let target_path = record.target_path.map(|path| redact(&path));
        self.rows
            .lock()
            .expect("audit lock poisoned")
            .push(AuditRow {
                timestamp: Utc::now(),
                device_id: record.device_id,
                provider: record.provider,
                conversation_id: record.conversation_id,
                action: record.action,
                target_path,
                result,
            });
    }

    pub fn list(&self) -> Vec<AuditRow> {
        self.rows.lock().expect("audit lock poisoned").clone()
    }
}

fn redact(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    if [
        "token",
        "secret",
        "password",
        "cookie",
        "authorization",
        "api_key",
        "api-key",
        "api key",
        "apikey",
        "body",
        "message",
        "content",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
    {
        "redacted".into()
    } else {
        value.to_owned()
    }
}
