use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Json;
use axum::body::Body;
use axum::extract::Extension;
use axum::middleware::{self, Next};
use axum::routing::get;
use chrono::Utc;
use http::Request;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::{ConversationKind, ConversationSummary, ProviderId};
use serde_json::json;

async fn transfer_count(
    Extension(counter): Extension<Arc<AtomicUsize>>,
) -> Json<serde_json::Value> {
    Json(json!({"transferRequests": counter.load(Ordering::Relaxed)}))
}

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
                write_state: None,
                write_block_code: None,
            }],
        )
        .await;
    let transfer_counter = Arc::new(AtomicUsize::new(0));
    let counter_for_middleware = transfer_counter.clone();
    let app = router(state)
        .route("/v1/mock/transfer-count", get(transfer_count))
        .layer(axum::Extension(transfer_counter))
        .layer(middleware::from_fn(
            move |request: Request<Body>, next: Next| {
                let counter = counter_for_middleware.clone();
                async move {
                    if request.uri().path().starts_with("/v1/transfers/") {
                        counter.fetch_add(1, Ordering::Relaxed);
                    }
                    next.run(request).await
                }
            },
        ));
    println!(
        "{}",
        serde_json::to_string(&json!({"pairing": payload, "bind": bind}))?
    );
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
