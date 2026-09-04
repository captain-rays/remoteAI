use std::sync::Arc;

use chrono::Utc;
use remote_ai_agent::adapters::ProviderAdapter;
use remote_ai_agent::adapters::codex::CodexAdapter;
use remote_ai_agent::adapters::mock::MockAdapter;
use remote_ai_agent::gateway::GatewayState;
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{ConversationKind, ProviderId};
use tokio::sync::RwLock;

fn state() -> GatewayState {
    let now = Utc::now();
    let mut pairing = PairingRegistry::new("mac", "http://127.0.0.1:8787", vec![4, 1]);
    pairing.issue("secret", now);
    GatewayState::new(Arc::new(RwLock::new(pairing)), 8)
}

#[tokio::test]
async fn injecting_adapters_populates_initial_session_catalog() {
    let state = state();
    let codex = Arc::new(MockAdapter::new(ProviderId::Codex));
    let claude = Arc::new(MockAdapter::new(ProviderId::Claude));
    codex.start(ConversationKind::Daily, None).await.unwrap();
    claude
        .start(ConversationKind::Project, Some("/tmp/project".into()))
        .await
        .unwrap();

    state
        .configure_runtime_state("/tmp", vec![codex, claude])
        .await;

    let sessions = state.sessions.read().await;
    assert_eq!(sessions[&ProviderId::Codex].len(), 1);
    assert_eq!(sessions[&ProviderId::Claude].len(), 1);
}

#[tokio::test]
async fn refresh_keeps_provider_sessions_separate() {
    let state = state();
    let codex = Arc::new(MockAdapter::new(ProviderId::Codex));
    let claude = Arc::new(MockAdapter::new(ProviderId::Claude));
    codex.start(ConversationKind::Daily, None).await.unwrap();
    claude.start(ConversationKind::Daily, None).await.unwrap();
    state.set_provider_adapters(vec![codex, claude]).await;

    let failed = state.refresh_provider_sessions().await;

    assert!(failed.is_empty());
    let sessions = state.sessions.read().await;
    assert_eq!(sessions[&ProviderId::Codex].len(), 1);
    assert_eq!(sessions[&ProviderId::Claude].len(), 1);
    assert!(
        sessions[&ProviderId::Codex]
            .iter()
            .all(|session| session.provider == ProviderId::Codex)
    );
    assert!(
        sessions[&ProviderId::Claude]
            .iter()
            .all(|session| session.provider == ProviderId::Claude)
    );
}

#[tokio::test]
async fn refresh_records_provider_errors_without_blocking_others() {
    let state = state();
    let good = Arc::new(MockAdapter::new(ProviderId::Claude));
    good.start(ConversationKind::Project, Some("/tmp/project".into()))
        .await
        .unwrap();
    let failing: Arc<dyn ProviderAdapter> =
        Arc::new(CodexAdapter::new("/definitely/missing/codex", "/tmp"));
    state.set_provider_adapters(vec![good, failing]).await;

    let failed = state.refresh_provider_sessions().await;

    assert_eq!(failed, vec![ProviderId::Codex]);
    let sessions = state.sessions.read().await;
    assert_eq!(sessions[&ProviderId::Claude].len(), 1);
    assert!(!sessions.contains_key(&ProviderId::Codex));
}
