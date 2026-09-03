use std::path::{Path, PathBuf};

use tokio::process::Command;

use crate::protocol::{ProviderId, ProviderStatus};

pub async fn discover_provider(
    provider: ProviderId,
    override_path: Option<&Path>,
) -> ProviderStatus {
    let path = override_path
        .map(Path::to_owned)
        .or_else(|| locate(provider_command(provider)));
    match path {
        Some(path) => discover_at(provider, &path).await,
        None => unavailable(provider, "executable not found"),
    }
}

pub async fn discover_at(provider: ProviderId, executable: &Path) -> ProviderStatus {
    if !executable.is_file() {
        return unavailable(provider, "executable not found");
    }
    match Command::new(executable).arg("--version").output().await {
        Ok(output) if output.status.success() => ProviderStatus {
            provider,
            available: true,
            executable_path: Some(executable.to_string_lossy().into_owned()),
            version: Some(String::from_utf8_lossy(&output.stdout).trim().to_owned()),
            reason: None,
        },
        Ok(output) => unavailable(
            provider,
            &format!("version command exited with {}", output.status),
        ),
        Err(error) => unavailable(provider, &format!("version command failed: {error}")),
    }
}

const fn provider_command(provider: ProviderId) -> &'static str {
    match provider {
        ProviderId::Codex => "codex",
        ProviderId::Claude => "claude",
    }
}

fn locate(command: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join(command))
        .find(|candidate| candidate.is_file())
}

fn unavailable(provider: ProviderId, reason: &str) -> ProviderStatus {
    ProviderStatus {
        provider,
        available: false,
        executable_path: None,
        version: None,
        reason: Some(reason.to_owned()),
    }
}
