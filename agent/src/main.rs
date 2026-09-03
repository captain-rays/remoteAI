use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
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
use remote_ai_agent::pairing::{PairingPayload, PairingRegistry};
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

/// Serialize only safe pairing metadata for startup diagnostics.
///
/// The QR payload itself is a bearer credential: logging it would expose the
/// one-time secret and Mac public key to anyone with access to agent stdout.
fn pairing_log_line(payload: &PairingPayload) -> Result<String, serde_json::Error> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct PairingMetadata<'a> {
        origin: &'a str,
        mac_id: &'a str,
        expires_at: chrono::DateTime<Utc>,
    }

    serde_json::to_string(&PairingMetadata {
        origin: &payload.origin,
        mac_id: &payload.mac_id,
        expires_at: payload.expires_at,
    })
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
    let mut pairing = PairingRegistry::new("mac-local", &config.public_origin, public_key);
    let payload = pairing.issue(&Uuid::new_v4().to_string(), Utc::now());
    println!("pairing issued: {}", pairing_log_line(&payload)?);
    if let Some(path) = std::env::var_os("REMOTEAI_PAIRING_FILE") {
        write_pairing_file(Path::new(&path), &payload)?;
        eprintln!("pairing payload written to REMOTEAI_PAIRING_FILE");
    } else {
        eprintln!("pairing payload not persisted; set REMOTEAI_PAIRING_FILE for local handoff");
    }
    let state = GatewayState::new(Arc::new(tokio::sync::RwLock::new(pairing)), 256);
    state.set_mac_private_key(key.to_bytes().into()).await;
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

fn write_pairing_file(path: &Path, payload: &PairingPayload) -> anyhow::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    if !parent.exists() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    } else if fs::metadata(parent)?.permissions().mode() & 0o077 != 0 {
        anyhow::bail!("pairing file parent must not be accessible by group/other");
    }
    let bytes = serde_json::to_vec(payload)?;
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
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

    #[test]
    fn pairing_log_line_redacts_secret_and_private_material() {
        let payload = PairingPayload {
            origin: "https://mac.example".into(),
            mac_id: "mac-1".into(),
            mac_public_key: vec![1, 2, 3],
            pairing_secret: "never-log-this-secret".into(),
            expires_at: Utc::now(),
        };

        let line = pairing_log_line(&payload).expect("metadata should serialize");

        assert!(!line.contains("pairingSecret"));
        assert!(!line.contains("never-log-this-secret"));
        assert!(!line.contains("macPublicKey"));
        assert!(line.contains("https://mac.example"));
        assert!(line.contains("mac-1"));
    }

    #[test]
    fn pairing_file_is_owner_only_and_contains_payload_without_logging() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("secure").join("pairing.json");
        let payload = PairingPayload {
            origin: "http://127.0.0.1:8787".into(),
            mac_id: "mac-1".into(),
            mac_public_key: vec![4, 1],
            pairing_secret: "one-time".into(),
            expires_at: Utc::now(),
        };
        write_pairing_file(&path, &payload).unwrap();
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let decoded: PairingPayload = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(decoded, payload);
    }
}
