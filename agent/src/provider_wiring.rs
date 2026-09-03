use std::sync::Arc;

use crate::adapters::ProviderAdapter;
use crate::gateway::GatewayState;

impl GatewayState {
    /// Inject provider adapters and publish a status-only diagnostics snapshot.
    /// Adapter instances remain owned by the caller; this method never persists
    /// credentials or conversation content.
    pub async fn set_provider_adapters(&self, adapters: Vec<Arc<dyn ProviderAdapter>>) {
        *self.provider_adapters.write().await = adapters.clone();
        self.diagnostics.refresh_from_adapters(&adapters).await;
    }

    /// Refresh each provider's lightweight session index independently.
    /// A provider failure is returned to the caller while successful providers
    /// are still committed to the per-provider session map.
    pub async fn refresh_provider_sessions(&self) -> Vec<crate::protocol::ProviderId> {
        let adapters = self.provider_adapters.read().await.clone();
        let mut failed = Vec::new();
        for adapter in adapters {
            let provider = adapter.status().await.provider;
            match adapter.list_conversations().await {
                Ok(sessions) => {
                    let sessions = sessions
                        .into_iter()
                        .filter(|session| session.provider == provider)
                        .collect();
                    self.sessions.write().await.insert(provider, sessions);
                }
                Err(_) => failed.push(provider),
            }
        }
        failed
    }
}
