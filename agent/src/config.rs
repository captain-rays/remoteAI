use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentConfig {
    pub bind: SocketAddr,
    /// Origin advertised in pairing payloads. A tunnel can override this
    /// without changing the local listener address.
    pub public_origin: String,
    pub state_dir: PathBuf,
}

impl AgentConfig {
    pub fn with_state_dir(path: impl AsRef<Path>) -> Self {
        let bind = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8787);
        let public_origin = std::env::var("REMOTEAI_PUBLIC_ORIGIN")
            .ok()
            .filter(|origin| !origin.trim().is_empty())
            .unwrap_or_else(|| format!("http://{bind}"));
        Self {
            bind,
            public_origin,
            state_dir: path.as_ref().to_owned(),
        }
    }
}

impl Default for AgentConfig {
    fn default() -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from);
        Self::with_state_dir(home.join("Library/Application Support/RemoteAI"))
    }
}
