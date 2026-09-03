use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::Utc;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use remote_ai_agent::adapters::claude::ClaudeAdapter;
use remote_ai_agent::adapters::codex::CodexAdapter;
use remote_ai_agent::adapters::{ConversationPage, ProviderAdapter};
use remote_ai_agent::config::AgentConfig;
use remote_ai_agent::crypto::load_or_create_private_key;
use remote_ai_agent::discovery::discover_provider;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ProviderId, ProviderStatus,
};
use remote_ai_agent::store::Store;
use tokio::sync::broadcast;
use uuid::Uuid;

struct ReportedAdapter {
    inner: Option<Arc<dyn ProviderAdapter>>,
    status: ProviderStatus,
    events: broadcast::Sender<ConversationEvent>,
}

impl ReportedAdapter {
    fn new(status: ProviderStatus, inner: Option<Arc<dyn ProviderAdapter>>) -> Self {
        let (events, _) = broadcast::channel(16);
        Self {
            inner,
            status,
            events,
        }
    }

    fn unavailable<T>(&self) -> anyhow::Result<T> {
        anyhow::bail!(
            "{:?} unavailable: {}",
            self.status.provider,
            self.status
                .reason
                .as_deref()
                .unwrap_or("provider unavailable")
        )
    }
}

#[async_trait]
impl ProviderAdapter for ReportedAdapter {
    async fn status(&self) -> ProviderStatus {
        self.status.clone()
    }

    async fn list_conversations(
        &self,
    ) -> anyhow::Result<Vec<remote_ai_agent::protocol::ConversationSummary>> {
        match &self.inner {
            Some(inner) => inner.list_conversations().await,
            None => self.unavailable(),
        }
    }

    async fn load_conversation(
        &self,
        id: &str,
        cursor: Option<String>,
    ) -> anyhow::Result<ConversationPage> {
        match &self.inner {
            Some(inner) => inner.load_conversation(id, cursor).await,
            None => self.unavailable(),
        }
    }

    async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> anyhow::Result<String> {
        match &self.inner {
            Some(inner) => inner.start(kind, cwd).await,
            None => self.unavailable(),
        }
    }

    async fn resume(&self, id: &str) -> anyhow::Result<()> {
        match &self.inner {
            Some(inner) => inner.resume(id).await,
            None => self.unavailable(),
        }
    }

    async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> anyhow::Result<()> {
        match &self.inner {
            Some(inner) => inner.send(id, text, attachments).await,
            None => self.unavailable(),
        }
    }

    async fn decide_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> anyhow::Result<()> {
        match &self.inner {
            Some(inner) => inner.decide_approval(request_id, decision).await,
            None => self.unavailable(),
        }
    }

    async fn interrupt(&self, id: &str) -> anyhow::Result<()> {
        match &self.inner {
            Some(inner) => inner.interrupt(id).await,
            None => self.unavailable(),
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<ConversationEvent> {
        match &self.inner {
            Some(inner) => inner.subscribe(),
            None => self.events.subscribe(),
        }
    }
}

fn adapters_from_statuses(
    home: PathBuf,
    statuses: Vec<ProviderStatus>,
) -> Vec<Arc<dyn ProviderAdapter>> {
    statuses
        .into_iter()
        .map(|status| {
            let inner = status.available.then(|| {
                let executable = status
                    .executable_path
                    .clone()
                    .expect("available provider executable");
                match status.provider {
                    ProviderId::Codex => Arc::new(CodexAdapter::new(executable, home.clone()))
                        as Arc<dyn ProviderAdapter>,
                    ProviderId::Claude => Arc::new(ClaudeAdapter::new(executable, home.clone()))
                        as Arc<dyn ProviderAdapter>,
                }
            });
            Arc::new(ReportedAdapter::new(status, inner)) as Arc<dyn ProviderAdapter>
        })
        .collect()
}

async fn discover_runtime_adapters(home: PathBuf) -> Vec<Arc<dyn ProviderAdapter>> {
    let mut statuses = Vec::with_capacity(2);
    for provider in [ProviderId::Codex, ProviderId::Claude] {
        statuses.push(discover_provider(provider, None).await);
    }
    adapters_from_statuses(home, statuses)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = AgentConfig::default();
    let store = Store::open(&config.state_dir).await?;
    let key = load_or_create_private_key(store.private_key_path())?;
    let public_key = key.public_key().to_encoded_point(false).as_bytes().to_vec();
    let mut pairing =
        PairingRegistry::new("mac-local", &format!("http://{}", config.bind), public_key);
    let payload = pairing.issue(&Uuid::new_v4().to_string(), Utc::now());
    println!("{}", serde_json::to_string(&payload)?);

    let state = GatewayState::new(Arc::new(tokio::sync::RwLock::new(pairing)), 256);
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from);
    state
        .set_provider_adapters(discover_runtime_adapters(home).await)
        .await;
    let listener = tokio::net::TcpListener::bind(config.bind).await?;
    println!(
        "{} listening on {}",
        remote_ai_agent::agent_name(),
        config.bind
    );
    axum::serve(listener, router(state)).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unavailable_provider_is_reported_without_startup_failure() {
        let status = ProviderStatus {
            provider: ProviderId::Claude,
            available: false,
            executable_path: None,
            version: None,
            reason: Some("executable not found".into()),
        };
        let adapters = adapters_from_statuses(PathBuf::from("/tmp"), vec![status]);
        assert_eq!(adapters.len(), 1);
        let reported = adapters[0].status().await;
        assert!(!reported.available);
        assert_eq!(reported.reason.as_deref(), Some("executable not found"));
    }

    #[tokio::test]
    async fn discovered_provider_metadata_is_preserved() {
        let status = ProviderStatus {
            provider: ProviderId::Codex,
            available: true,
            executable_path: Some("/opt/homebrew/bin/codex".into()),
            version: Some("codex-cli 0.144.4".into()),
            reason: None,
        };
        let reported = adapters_from_statuses(PathBuf::from("/tmp"), vec![status])[0]
            .status()
            .await;
        assert!(reported.available);
        assert_eq!(reported.version.as_deref(), Some("codex-cli 0.144.4"));
    }
}
