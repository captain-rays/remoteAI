use chrono::Utc;
use remote_ai_agent::pairing::PairingRegistry;
use remote_ai_agent::store::Store;

/// Pair a device against one registry, then build a second one the way a
/// restarted agent does, and check the phone is still known.
#[tokio::test]
async fn a_paired_phone_survives_an_agent_restart() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).await.unwrap();

    let mut registry = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    let payload = registry.issue("secret-1", Utc::now());
    let device = registry
        .pair(
            &payload.pairing_secret,
            "phone-1",
            "Kangle's iPhone",
            vec![4, 2],
            Utc::now(),
        )
        .unwrap();
    store.upsert_device(&device).await.unwrap();

    // The agent restarts: a brand new registry, rebuilt from the store.
    let mut restarted = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    restarted.restore(store.load_devices().await.unwrap());

    restarted
        .authenticate("phone-1")
        .expect("a phone paired once must not have to pair again after a restart");
    assert_eq!(restarted.device_public_key("phone-1").unwrap(), vec![4, 2]);
}

#[tokio::test]
async fn a_revoked_phone_stays_revoked_across_a_restart() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).await.unwrap();

    let mut registry = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    let payload = registry.issue("secret-1", Utc::now());
    let device = registry
        .pair(
            &payload.pairing_secret,
            "phone-1",
            "iPhone",
            vec![4, 2],
            Utc::now(),
        )
        .unwrap();
    store.upsert_device(&device).await.unwrap();

    let revoked_at = Utc::now();
    registry.revoke("phone-1", revoked_at).unwrap();
    store
        .set_device_revoked("phone-1", revoked_at)
        .await
        .unwrap();

    let mut restarted = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    restarted.restore(store.load_devices().await.unwrap());

    restarted
        .authenticate("phone-1")
        .expect_err("revoking a phone must outlive the process that revoked it");
}

#[tokio::test]
async fn a_pairing_secret_is_not_restored_with_the_devices() {
    // Only devices are persisted. A one-time secret that survived a restart
    // could be replayed against the new process.
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(temp.path()).await.unwrap();
    let mut registry = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    let payload = registry.issue("secret-1", Utc::now());
    let device = registry
        .pair(
            &payload.pairing_secret,
            "phone-1",
            "iPhone",
            vec![4, 2],
            Utc::now(),
        )
        .unwrap();
    store.upsert_device(&device).await.unwrap();

    let mut restarted = PairingRegistry::new("mac-local", "https://mac.example", vec![4, 1]);
    restarted.restore(store.load_devices().await.unwrap());

    restarted
        .pair("secret-1", "phone-2", "Another", vec![4, 3], Utc::now())
        .expect_err("a secret from before the restart must not still pair a new device");
}
