use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentConfig {
    pub bind: SocketAddr,
    pub state_dir: PathBuf,
}

impl AgentConfig {
    pub fn with_state_dir(path: impl AsRef<Path>) -> Self {
        Self {
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8787),
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
