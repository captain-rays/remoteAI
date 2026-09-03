use std::sync::Arc;

use crate::adapters::ProviderAdapter;
use crate::gateway::GatewayState;

impl GatewayState {
    /// Inject provider adapters and publish a status-only diagnostics snapshot.
    /// Adapter instances remain owned by the caller; this method never persists
    /// credentials or conversation content.
    pub async fn set_provider_adapters(&self, adapters: Vec<Arc<dyn ProviderAdapter>>) {
        self.diagnostics.refresh_from_adapters(&adapters).await;
    }
}
