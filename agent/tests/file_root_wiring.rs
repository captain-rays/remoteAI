use std::sync::Arc;

use axum::body::{Body, to_bytes};
use http::{Request, StatusCode};
use remote_ai_agent::adapters::mock::MockAdapter;
use remote_ai_agent::adapters::ProviderAdapter;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::protocol::ProviderId;
use serde_json::json;
use tempfile::tempdir;
use tokio::sync::RwLock;
use tower::ServiceExt;
use chrono::Utc;

fn paired_state() -> GatewayState {
    let now = Utc::now();
    let mut registry = PairingRegistry::new("mac-1", "https://agent.example", vec![4, 1]);
    registry.issue("secret", now);
    registry.pair("secret", "phone-1", "Phone", vec![4, 2], now).unwrap();
    GatewayState::new(Arc::new(RwLock::new(registry)), 8)
}

#[tokio::test]
async fn runtime_configuration_wires_file_root_before_router_serves_requests() {
    let root = tempdir().unwrap();
    std::fs::write(root.path().join("fixture.txt"), "fixture").unwrap();
    let state = paired_state();
    let adapter: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::new(ProviderId::Claude));
    state
        .configure_runtime_state(root.path(), vec![adapter])
        .await;
    let app = router(state);
    let list = app
        .clone()
        .oneshot(
            Request::get(format!(
                "/v1/files/list?path={}",
                root.path().canonicalize().unwrap().display()
            ))
                .header("x-remoteai-device", "phone-1")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(list.status(), StatusCode::OK);
    let body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
    assert!(String::from_utf8(body.to_vec()).unwrap().contains("fixture.txt"));
    let create = app
        .oneshot(
            Request::post("/v1/transfers/create")
                .header("x-remoteai-device", "phone-1")
                .header("content-type", "application/json")
                .body(Body::from(json!({"path":"created.txt"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create.status(), StatusCode::OK);
}
