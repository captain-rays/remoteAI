use std::fs;
use std::os::unix::fs::PermissionsExt;

use chrono::{Duration, TimeZone, Utc};
use remote_ai_agent::crypto::{
    CryptoBox, derive_directional_keys, derive_shared_secret, load_or_create_private_key,
};
use remote_ai_agent::pairing::{PairingError, PairingRegistry};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vector {
    private_key: String,
    peer_public_key: String,
    shared_secret: String,
    mac_to_ios_key: String,
    ios_to_mac_key: String,
    aes_key: String,
    nonce_prefix: String,
    counter: u64,
    plaintext: String,
    ciphertext_and_tag: String,
}

fn hex(value: &str) -> Vec<u8> {
    (0..value.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&value[index..index + 2], 16).unwrap())
        .collect()
}

#[test]
fn matches_p256_hkdf_and_aes_gcm_vectors() {
    let vector: Vector = serde_json::from_str(include_str!(
        "../../protocol/v1/fixtures/crypto-vectors.json"
    ))
    .unwrap();
    let shared =
        derive_shared_secret(&hex(&vector.private_key), &hex(&vector.peer_public_key)).unwrap();
    assert_eq!(shared.as_slice(), hex(&vector.shared_secret));

    let keys = derive_directional_keys(&shared, "mac-1", "phone-1").unwrap();
    assert_eq!(keys.mac_to_ios.as_slice(), hex(&vector.mac_to_ios_key));
    assert_eq!(keys.ios_to_mac.as_slice(), hex(&vector.ios_to_mac_key));

    let crypto = CryptoBox::new(
        hex(&vector.aes_key).try_into().unwrap(),
        hex(&vector.nonce_prefix).try_into().unwrap(),
    );
    let encrypted = crypto
        .encrypt(vector.counter, b"", &hex(&vector.plaintext))
        .unwrap();
    assert_eq!(encrypted, hex(&vector.ciphertext_and_tag));
}

#[test]
fn rejects_tampering_and_replayed_or_out_of_order_counters() {
    let crypto = CryptoBox::new([7; 32], *b"MAC>");
    let mut receiver = crypto.receiver();
    let ciphertext = crypto.encrypt(1, b"route", b"payload").unwrap();
    assert_eq!(
        receiver.decrypt(1, b"route", &ciphertext).unwrap(),
        b"payload"
    );
    assert!(receiver.decrypt(1, b"route", &ciphertext).is_err());
    assert!(receiver.decrypt(0, b"route", &ciphertext).is_err());

    let mut tampered = ciphertext;
    tampered[0] ^= 1;
    assert!(crypto.receiver().decrypt(2, b"route", &tampered).is_err());
}

#[test]
fn pairing_secret_is_five_minute_single_use_and_revocable() {
    let now = Utc.with_ymd_and_hms(2026, 9, 3, 0, 0, 0).unwrap();
    let mut registry = PairingRegistry::new("mac-1", "https://agent.example", vec![4, 1]);
    let payload = registry.issue("one-time-secret", now);
    assert_eq!(payload.expires_at, now + Duration::minutes(5));

    registry
        .pair("one-time-secret", "phone-1", "My iPhone", vec![4, 2], now)
        .unwrap();
    assert_eq!(
        registry
            .pair("one-time-secret", "phone-2", "Other", vec![4, 3], now,)
            .unwrap_err(),
        PairingError::SecretAlreadyUsed
    );

    registry.revoke("phone-1", now).unwrap();
    assert_eq!(
        registry.authenticate("phone-1"),
        Err(PairingError::DeviceRevoked)
    );

    let expired = registry.issue("expired", now);
    assert_eq!(
        registry
            .pair(
                &expired.pairing_secret,
                "phone-3",
                "Late",
                vec![4, 4],
                now + Duration::minutes(6),
            )
            .unwrap_err(),
        PairingError::SecretExpired
    );
}

#[test]
fn mac_private_key_is_persistent_and_owner_only() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("agent-private-key.bin");
    let first = load_or_create_private_key(&path).unwrap();
    let second = load_or_create_private_key(&path).unwrap();
    assert_eq!(
        first.public_key().to_sec1_bytes(),
        second.public_key().to_sec1_bytes()
    );
    assert_eq!(
        fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
