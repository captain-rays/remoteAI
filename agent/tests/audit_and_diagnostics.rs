use remote_ai_agent::audit::{AuditLog, AuditRecord};
use remote_ai_agent::diagnostics::{Diagnostics, ProviderHealth};
use remote_ai_agent::protocol::{ProviderId, ProviderStatus};
use remote_ai_agent::tunnel::TunnelManager;

#[test]
fn audit_redacts_credentials_bodies_and_file_contents() {
    let log = AuditLog::new();
    log.record(AuditRecord {
        device_id: "phone-1".into(),
        provider: Some(ProviderId::Codex),
        conversation_id: Some("thread-1".into()),
        action: "conversation.send".into(),
        target_path: Some("/tmp/project".into()),
        result: "ok token=secret body=private message api_key=abc".into(),
    });
    let json = serde_json::to_string(&log.list()).unwrap();
    assert!(json.contains("conversation.send"));
    assert!(!json.contains("secret"));
    assert!(!json.contains("private message"));
    assert!(!json.contains("api_key"));
}

#[tokio::test]
async fn diagnostics_report_versions_and_tunnel_reachability_without_secrets() {
    let diagnostics = Diagnostics::new(
        "0.1.0",
        vec![ProviderHealth {
            status: ProviderStatus {
                provider: ProviderId::Claude,
                available: false,
                executable_path: None,
                version: None,
                reason: Some("not installed".into()),
            },
            reachable: false,
        }],
    );
    let report = diagnostics
        .report(TunnelManager::from_version("cloudflared version 2026.2.0"))
        .await;
    let json = serde_json::to_string(&report).unwrap();
    assert!(json.contains("2026.2.0"));
    assert!(json.contains("not installed"));
    assert!(!json.contains("token"));
}
