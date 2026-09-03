use serde::Serialize;

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
    providers: Vec<ProviderHealth>,
}

impl Diagnostics {
    pub fn new(agent_version: impl Into<String>, providers: Vec<ProviderHealth>) -> Self {
        Self {
            agent_version: agent_version.into(),
            providers,
        }
    }

    pub async fn report(&self, tunnel: TunnelManager) -> DiagnosticsReport {
        DiagnosticsReport {
            agent_version: self.agent_version.clone(),
            providers: self.providers.clone(),
            tunnel: tunnel.status().await,
        }
    }
}
