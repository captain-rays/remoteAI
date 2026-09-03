use std::sync::Arc;

use chrono::Utc;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use remote_ai_agent::config::AgentConfig;
use remote_ai_agent::crypto::load_or_create_private_key;
use remote_ai_agent::gateway::{GatewayState, router};
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::store::Store;
use uuid::Uuid;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = AgentConfig::default();
    let store = Store::open(&config.state_dir).await?;
    let key = load_or_create_private_key(store.private_key_path())?;
    let public_key = key.public_key().to_encoded_point(false).as_bytes().to_vec();
    let mut pairing =
        PairingRegistry::new("mac-local", &format!("http://{}", config.bind), public_key);
    let payload = pairing.issue(&Uuid::new_v4().to_string(), Utc::now());
    println!("{}", serde_json::to_string(&payload)?);

    let state = GatewayState::new(Arc::new(tokio::sync::RwLock::new(pairing)), 256);
    let listener = tokio::net::TcpListener::bind(config.bind).await?;
    println!(
        "{} listening on {}",
        remote_ai_agent::agent_name(),
        config.bind
    );
    axum::serve(listener, router(state)).await?;
    Ok(())
}
