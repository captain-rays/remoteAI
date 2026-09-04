use std::path::Path;
use std::sync::Arc;

use crate::adapters::ProviderAdapter;
use crate::gateway::GatewayState;

impl GatewayState {
    /// Apply production runtime wiring in one place so the adapters and file
    /// service share the exact same HOME-derived root.
    pub async fn configure_runtime_state(
        &self,
        home: impl AsRef<Path>,
        adapters: Vec<Arc<dyn ProviderAdapter>>,
    ) {
        self.set_file_root(home).await;
        self.set_provider_adapters(adapters).await;
        let _ = self.refresh_provider_sessions().await;
    }

    /// Inject provider adapters and publish diagnostics. Catalog indexing is
    /// deliberately left to an explicit provider read or production startup,
    /// so tests and other callers can preserve provider-scoped access.
    pub async fn set_provider_adapters(&self, adapters: Vec<Arc<dyn ProviderAdapter>>) {
        *self.provider_adapters.write().await = adapters.clone();
        self.diagnostics.refresh_from_adapters(&adapters).await;
    }

    /// Refresh one provider's lightweight session index. Callers are explicit
    /// reads — opening a list or pulling to refresh — so nothing here runs on a
    /// timer or a file watcher. Returns false when the provider could not be
    /// indexed; the previous index is then left untouched.
    pub async fn refresh_provider(&self, provider: crate::protocol::ProviderId) -> bool {
        let adapters = self.provider_adapters.read().await.clone();
        for adapter in adapters {
            if adapter.status().await.provider != provider {
                continue;
            }
            let Ok(sessions) = adapter.list_conversations().await else {
                return false;
            };
            let sessions = sessions
                .into_iter()
                .filter(|session| session.provider == provider)
                .collect();
            self.sessions.write().await.insert(provider, sessions);
            return true;
        }
        false
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
