use std::sync::Arc;

use chrono::Utc;
use remote_ai_agent::adapters::ProviderAdapter;
use remote_ai_agent::adapters::mock::MockAdapter;
use remote_ai_agent::diagnostics::Diagnostics;
use remote_ai_agent::gateway::GatewayState;
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::ProviderId;
use remote_ai_agent::tunnel::TunnelManager;
use tokio::sync::RwLock;

fn state() -> GatewayState {
    let now = Utc::now();
    let mut pairing = PairingRegistry::new("mac", "http://127.0.0.1:8787", vec![4, 1]);
    pairing.issue("secret", now);
    GatewayState::new(Arc::new(RwLock::new(pairing)), 8)
}

#[tokio::test]
async fn gateway_injects_provider_adapters_into_diagnostics() {
    let state = state();
    let adapters: Vec<Arc<dyn ProviderAdapter>> = vec![
        Arc::new(MockAdapter::new(ProviderId::Codex)),
        Arc::new(MockAdapter::new(ProviderId::Claude)),
    ];

    state.set_provider_adapters(adapters).await;

    let report = state
        .diagnostics
        .report(TunnelManager::from_version("test"))
        .await;
    assert_eq!(report.providers.len(), 2);
    assert!(
        report
            .providers
            .iter()
            .all(|provider| provider.status.available && provider.reachable)
    );
    assert!(
        report
            .providers
            .iter()
            .any(|provider| provider.status.provider == ProviderId::Codex)
    );
    assert!(
        report
            .providers
            .iter()
            .any(|provider| provider.status.provider == ProviderId::Claude)
    );
}

#[tokio::test]
async fn diagnostics_can_refresh_provider_status_after_injection() {
    let state = state();
    let codex = Arc::new(MockAdapter::new(ProviderId::Codex));
    state
        .set_provider_adapters(vec![codex as Arc<dyn ProviderAdapter>])
        .await;
    let first = state
        .diagnostics
        .report(TunnelManager::from_version("test"))
        .await;
    assert_eq!(first.providers[0].status.provider, ProviderId::Codex);

    state
        .set_provider_adapters(vec![Arc::new(MockAdapter::new(ProviderId::Claude))])
        .await;
    let second = state
        .diagnostics
        .report(TunnelManager::from_version("test"))
        .await;
    assert_eq!(second.providers.len(), 1);
    assert_eq!(second.providers[0].status.provider, ProviderId::Claude);
}

#[test]
fn diagnostics_still_supports_static_provider_health() {
    let diagnostics = Diagnostics::new("test", Vec::new());
    assert_eq!(diagnostics.provider_count(), 0);
}
