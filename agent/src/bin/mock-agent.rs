use std::sync::Arc;

use chrono::Utc;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{ConversationKind, ConversationSummary, ProviderId};
use serde_json::json;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let bind = std::env::var("REMOTEAI_MOCK_BIND").unwrap_or_else(|_| "127.0.0.1:8788".into());
    let mut pairing = PairingRegistry::new("mock-mac", &format!("http://{bind}"), vec![4, 1]);
    let payload = pairing.issue("mock-secret", Utc::now());
    let state = GatewayState::new(Arc::new(tokio::sync::RwLock::new(pairing)), 32);
    state
        .set_sessions(
            ProviderId::Codex,
            vec![ConversationSummary {
                id: "mock-daily".into(),
                provider: ProviderId::Codex,
                kind: ConversationKind::Daily,
                title: "Mock daily session".into(),
                project_id: None,
                project_path: None,
                updated_at: Utc::now(),
                status: "idle".into(),
            }],
        )
        .await;
    println!(
        "{}",
        serde_json::to_string(&json!({"pairing": payload, "bind": bind}))?
    );
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    axum::serve(listener, router(state)).await?;
    Ok(())
}
