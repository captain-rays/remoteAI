use std::process::Stdio;

use serde::Serialize;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelStatus {
    pub executable: String,
    pub version: Option<String>,
    pub reachable: bool,
    pub configuration: String,
}

#[derive(Debug, Clone)]
pub struct TunnelManager {
    version_override: Option<String>,
}

impl TunnelManager {
    pub fn new() -> Self {
        Self {
            version_override: None,
        }
    }

    pub fn from_version(version: impl Into<String>) -> Self {
        Self {
            version_override: Some(version.into()),
        }
    }

    pub async fn status(&self) -> TunnelStatus {
        if let Some(version) = &self.version_override {
            return TunnelStatus {
                executable: "cloudflared".into(),
                version: Some(version.clone()),
                reachable: true,
                configuration:
                    "localhost-only forwarding; configure Named or Quick Tunnel externally".into(),
            };
        }
        let output = Command::new("cloudflared")
            .arg("--version")
            .stdin(Stdio::null())
            .output()
            .await;
        match output {
            Ok(output) if output.status.success() => TunnelStatus {
                executable: "cloudflared".into(),
                version: Some(String::from_utf8_lossy(&output.stdout).trim().into()),
                reachable: true,
                configuration:
                    "localhost-only forwarding; configure Named or Quick Tunnel externally".into(),
            },
            _ => TunnelStatus {
                executable: "cloudflared".into(),
                version: None,
                reachable: false,
                configuration: "cloudflared is unavailable; Agent remains localhost-only".into(),
            },
        }
    }
}

impl Default for TunnelManager {
    fn default() -> Self {
        Self::new()
    }
}
