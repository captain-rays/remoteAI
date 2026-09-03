use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::Path;

use remote_ai_agent::config::AgentConfig;
use remote_ai_agent::discovery::{discover_at, discover_provider};
use remote_ai_agent::protocol::ProviderId;
use remote_ai_agent::store::Store;
use tempfile::tempdir;

#[test]
fn configuration_is_localhost_only_and_state_is_overrideable() {
    let config = AgentConfig::default();
    assert_eq!(config.bind.to_string(), "127.0.0.1:8787");
    assert!(
        config
            .state_dir
            .ends_with("Library/Application Support/RemoteAI")
    );

    let temp = tempdir().unwrap();
    let overridden = AgentConfig::with_state_dir(temp.path());
    assert_eq!(overridden.state_dir, temp.path());
}

#[tokio::test]
async fn store_creates_metadata_only_schema_with_private_permissions() {
    let temp = tempdir().unwrap();
    let state = temp.path().join("state");
    assert!(state.starts_with(temp.path()));
    let store = Store::open(&state).await.unwrap();

    for path in [store.database_path(), store.private_key_path()] {
        let mode = fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "{} must be owner-only", path.display());
    }

    let tables = store.table_names().await.unwrap();
    for expected in [
        "devices",
        "session_index",
        "projects",
        "event_buffer",
        "transfers",
        "audit_log",
    ] {
        assert!(tables.contains(&expected.to_owned()), "missing {expected}");
    }
}

#[tokio::test]
async fn discovery_records_path_and_version_and_missing_is_non_fatal() {
    let temp = tempdir().unwrap();
    let executable = temp.path().join("codex");
    fs::write(&executable, "#!/bin/sh\necho 'codex-cli 9.9.9'\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();

    let found = discover_at(ProviderId::Codex, &executable).await;
    assert!(found.available);
    assert_eq!(found.executable_path.as_deref(), executable.to_str());
    assert_eq!(found.version.as_deref(), Some("codex-cli 9.9.9"));

    let missing = discover_at(ProviderId::Claude, Path::new("/definitely/missing/claude")).await;
    assert!(!missing.available);
    assert!(missing.reason.unwrap().contains("not found"));

    let dangling = temp.path().join("dangling");
    symlink("does-not-exist", &dangling).unwrap();
    let status = discover_provider(ProviderId::Claude, Some(&dangling)).await;
    assert!(!status.available);
}
