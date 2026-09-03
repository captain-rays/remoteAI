use std::sync::{Arc, RwLock};

use serde::Serialize;

use crate::adapters::ProviderAdapter;
use crate::protocol::ProviderStatus;
use crate::tunnel::{TunnelManager, TunnelStatus};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderHealth {
    pub status: ProviderStatus,
    pub reachable: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsReport {
    pub agent_version: String,
    pub providers: Vec<ProviderHealth>,
    pub tunnel: TunnelStatus,
}

#[derive(Debug, Clone)]
pub struct Diagnostics {
    agent_version: String,
    providers: Arc<RwLock<Vec<ProviderHealth>>>,
}

impl Diagnostics {
    pub fn new(agent_version: impl Into<String>, providers: Vec<ProviderHealth>) -> Self {
        Self {
            agent_version: agent_version.into(),
            providers: Arc::new(RwLock::new(providers)),
        }
    }

    /// Refreshes the diagnostics snapshot from the currently configured adapters.
    /// No adapter output other than status metadata is retained.
    pub async fn refresh_from_adapters(&self, adapters: &[Arc<dyn ProviderAdapter>]) {
        let mut providers = Vec::with_capacity(adapters.len());
        for adapter in adapters {
            let status = adapter.status().await;
            providers.push(ProviderHealth {
                reachable: status.available,
                status,
            });
        }
        if let Ok(mut current) = self.providers.write() {
            *current = providers;
        }
    }

    pub fn provider_count(&self) -> usize {
        self.providers
            .read()
            .map(|providers| providers.len())
            .unwrap_or(0)
    }

    pub async fn report(&self, tunnel: TunnelManager) -> DiagnosticsReport {
        DiagnosticsReport {
            agent_version: self.agent_version.clone(),
            providers: self
                .providers
                .read()
                .map(|providers| providers.clone())
                .unwrap_or_default(),
            tunnel: tunnel.status().await,
        }
    }
}
