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
use remote_ai_agent::config::resolve_home;
use remote_ai_agent::crypto::load_or_create_private_key;
use remote_ai_agent::discovery::discover_provider;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::{PairingPayload, PairingRegistry};
use remote_ai_agent::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ProjectSummary, ProviderId,
    ProviderStatus, WriteState,
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

    async fn list_daily_conversations(
        &self,
    ) -> anyhow::Result<Vec<remote_ai_agent::protocol::ConversationSummary>> {
        match &self.inner {
            Some(inner) => inner.list_daily_conversations().await,
            None => self.unavailable(),
        }
    }

    fn daily_catalog_diagnostic_code(&self) -> Option<&'static str> {
        self.inner
            .as_ref()
            .and_then(|inner| inner.daily_catalog_diagnostic_code())
    }

    async fn list_projects(&self) -> anyhow::Result<Vec<ProjectSummary>> {
        match &self.inner {
            Some(inner) => inner.list_projects().await,
            None => self.unavailable(),
        }
    }

    async fn list_project_conversations(
        &self,
        project_id: &str,
    ) -> anyhow::Result<Vec<remote_ai_agent::protocol::ConversationSummary>> {
        match &self.inner {
            Some(inner) => inner.list_project_conversations(project_id).await,
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

    async fn write_availability(&self, id: &str) -> anyhow::Result<WriteState> {
        match &self.inner {
            Some(inner) => inner.write_availability(id).await,
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
                    ProviderId::Claude => Arc::new(
                        ClaudeAdapter::new(executable, home.clone())
                            // Opt-in override for a Mac whose configured
                            // default model the account cannot use.
                            .with_model(std::env::var("REMOTEAI_CLAUDE_MODEL").ok())
                            .with_permission_mode(
                                std::env::var("REMOTEAI_CLAUDE_PERMISSION_MODE").ok(),
                            ),
                    ) as Arc<dyn ProviderAdapter>,
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
    let home = resolve_home();
    state
        .configure_runtime_state(&home, discover_runtime_adapters(home.clone()).await)
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
    use std::sync::Mutex;

    use remote_ai_agent::adapters::ConversationPage;
    use remote_ai_agent::protocol::{ConversationSummary, ProjectSummary, WriteState};

    struct ReportingProbe {
        status: ProviderStatus,
        daily: Vec<ConversationSummary>,
        projects: Vec<ProjectSummary>,
        project_conversations: Vec<ConversationSummary>,
        write_state: WriteState,
        calls: Arc<Mutex<Vec<String>>>,
        events: broadcast::Sender<ConversationEvent>,
    }

    impl ReportingProbe {
        fn record(&self, call: impl Into<String>) {
            self.calls.lock().unwrap().push(call.into());
        }
    }

    #[async_trait]
    impl ProviderAdapter for ReportingProbe {
        async fn status(&self) -> ProviderStatus {
            self.status.clone()
        }

        async fn list_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
            self.record("list_conversations");
            Ok(self.project_conversations.clone())
        }

        async fn list_daily_conversations(&self) -> anyhow::Result<Vec<ConversationSummary>> {
            self.record("list_daily_conversations");
            Ok(self.daily.clone())
        }

        fn daily_catalog_diagnostic_code(&self) -> Option<&'static str> {
            Some("probe_daily_catalog")
        }

        async fn list_projects(&self) -> anyhow::Result<Vec<ProjectSummary>> {
            self.record("list_projects");
            Ok(self.projects.clone())
        }

        async fn list_project_conversations(
            &self,
            project_id: &str,
        ) -> anyhow::Result<Vec<ConversationSummary>> {
            self.record(format!("list_project_conversations:{project_id}"));
            Ok(self.project_conversations.clone())
        }

        async fn load_conversation(
            &self,
            _id: &str,
            _cursor: Option<String>,
        ) -> anyhow::Result<ConversationPage> {
            anyhow::bail!("not part of this probe")
        }

        async fn start(
            &self,
            _kind: ConversationKind,
            _cwd: Option<PathBuf>,
        ) -> anyhow::Result<String> {
            anyhow::bail!("not part of this probe")
        }

        async fn resume(&self, _id: &str) -> anyhow::Result<()> {
            anyhow::bail!("not part of this probe")
        }

        async fn send(
            &self,
            _id: &str,
            _text: String,
            _attachments: Vec<PathBuf>,
        ) -> anyhow::Result<()> {
            anyhow::bail!("not part of this probe")
        }

        async fn decide_approval(
            &self,
            _request_id: &str,
            _decision: ApprovalDecision,
        ) -> anyhow::Result<()> {
            anyhow::bail!("not part of this probe")
        }

        async fn interrupt(&self, _id: &str) -> anyhow::Result<()> {
            anyhow::bail!("not part of this probe")
        }

        async fn write_availability(&self, id: &str) -> anyhow::Result<WriteState> {
            self.record(format!("write_availability:{id}"));
            Ok(self.write_state)
        }

        fn subscribe(&self) -> broadcast::Receiver<ConversationEvent> {
            self.events.subscribe()
        }
    }

    fn reporting_probe(
        provider: ProviderId,
        calls: Arc<Mutex<Vec<String>>>,
    ) -> (
        ProviderStatus,
        ReportingProbe,
        ProjectSummary,
        ConversationSummary,
    ) {
        let (events, _) = broadcast::channel(4);
        let project = ProjectSummary {
            id: format!("{provider:?}-project"),
            provider,
            canonical_path: "/workspace/project".into(),
            display_path: "project".into(),
            title: "Project".into(),
            updated_at: Utc::now(),
            available: true,
        };
        let conversation = ConversationSummary {
            id: format!("{provider:?}-conversation"),
            provider,
            kind: ConversationKind::Project,
            title: "Project conversation".into(),
            project_id: Some(project.id.clone()),
            project_path: Some(project.canonical_path.clone()),
            updated_at: Utc::now(),
            status: "idle".into(),
            write_state: Some(WriteState::Busy),
            write_block_code: Some("probe_busy".into()),
        };
        let status = ProviderStatus {
            provider,
            available: true,
            executable_path: Some("probe".into()),
            version: Some("1.0.0".into()),
            reason: None,
        };
        let probe = ReportingProbe {
            status: status.clone(),
            daily: vec![ConversationSummary {
                id: format!("{provider:?}-daily"),
                kind: ConversationKind::Daily,
                project_id: None,
                project_path: None,
                ..conversation.clone()
            }],
            projects: vec![project.clone()],
            project_conversations: vec![conversation.clone()],
            write_state: WriteState::Busy,
            calls,
            events,
        };
        (status, probe, project, conversation)
    }

    #[tokio::test]
    async fn reported_adapter_forwards_catalog_and_capability_views_for_both_providers() {
        for provider in [ProviderId::Codex, ProviderId::Claude] {
            let calls = Arc::new(Mutex::new(Vec::new()));
            let (status, probe, project, conversation) = reporting_probe(provider, calls.clone());
            let reported = ReportedAdapter::new(status, Some(Arc::new(probe)));

            assert_eq!(reported.list_daily_conversations().await.unwrap().len(), 1);
            assert_eq!(
                reported.daily_catalog_diagnostic_code(),
                Some("probe_daily_catalog")
            );
            assert_eq!(
                reported.list_projects().await.unwrap(),
                vec![project.clone()]
            );
            assert_eq!(
                reported
                    .list_project_conversations(&project.id)
                    .await
                    .unwrap(),
                vec![conversation.clone()]
            );
            assert_eq!(
                reported.write_availability(&conversation.id).await.unwrap(),
                WriteState::Busy
            );
            assert_eq!(
                *calls.lock().unwrap(),
                vec![
                    "list_daily_conversations".to_owned(),
                    "list_projects".to_owned(),
                    format!("list_project_conversations:{}", project.id),
                    format!("write_availability:{}", conversation.id),
                ]
            );
        }
    }

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
