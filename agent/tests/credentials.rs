//! Keeping and restoring provider credentials.

use std::fs;
use std::os::unix::fs::PermissionsExt;

use remote_ai_agent::credentials::{
    AccountVault, InMemorySecrets, Keychain, LiveCredential, SecretStore,
};
use remote_ai_agent::protocol::ProviderId;

#[test]
fn a_missing_credential_reads_as_absent_rather_than_failing() {
    // "Logged out" and "something went wrong" have to be distinguishable:
    // one is a normal state the phone displays, the other is an error.
    let home = tempfile::tempdir().unwrap();
    let secrets = InMemorySecrets::default();
    let codex = LiveCredential::codex(home.path());
    assert!(codex.read(&secrets).unwrap().is_none());

    let claude = LiveCredential::claude("nobody");
    assert!(claude.read(&secrets).unwrap().is_none());
}

#[test]
fn a_restored_file_credential_is_readable_only_by_its_owner() {
    // The file holds a refresh token. Codex writes it 0600 and so must we —
    // restoring an account must not be the moment it becomes readable by
    // everyone on the Mac.
    let home = tempfile::tempdir().unwrap();
    let secrets = InMemorySecrets::default();
    let codex = LiveCredential::codex(home.path());

    codex.write(&secrets, br#"{"tokens":{"access_token":"a"}}"#).unwrap();

    let path = home.path().join(".codex/auth.json");
    let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "credential file mode");
    let parent = fs::metadata(home.path().join(".codex")).unwrap();
    assert_eq!(parent.permissions().mode() & 0o077, 0, "directory is private");
    assert_eq!(
        codex.read(&secrets).unwrap().unwrap(),
        br#"{"tokens":{"access_token":"a"}}"#
    );
}

#[test]
fn clearing_a_credential_that_is_already_gone_is_not_an_error() {
    // Logging out twice, or logging out of an account that expired on its
    // own, is an ordinary thing for someone to do from a phone.
    let home = tempfile::tempdir().unwrap();
    let secrets = InMemorySecrets::default();
    let codex = LiveCredential::codex(home.path());
    codex.clear(&secrets).unwrap();
    codex.write(&secrets, b"x").unwrap();
    codex.clear(&secrets).unwrap();
    codex.clear(&secrets).unwrap();
    assert!(codex.read(&secrets).unwrap().is_none());
}

#[test]
fn a_snapshot_round_trips_byte_for_byte() {
    // A credential is opaque. Anything that reformats it — a JSON reparse, a
    // trailing newline, a lossy string conversion — can invalidate it.
    let vault = AccountVault::new(Box::new(InMemorySecrets::default()));
    let secret: Vec<u8> = (0u8..=255).collect();

    vault.save(ProviderId::Codex, "work", &secret).unwrap();

    assert_eq!(vault.load(ProviderId::Codex, "work").unwrap().unwrap(), secret);
}

#[test]
fn accounts_are_scoped_to_their_provider_and_label() {
    let vault = AccountVault::new(Box::new(InMemorySecrets::default()));
    vault.save(ProviderId::Codex, "work", b"codex-work").unwrap();
    vault.save(ProviderId::Claude, "work", b"claude-work").unwrap();
    vault.save(ProviderId::Codex, "home", b"codex-home").unwrap();

    assert_eq!(
        vault.load(ProviderId::Codex, "work").unwrap().unwrap(),
        b"codex-work"
    );
    assert_eq!(
        vault.load(ProviderId::Claude, "work").unwrap().unwrap(),
        b"claude-work"
    );

    vault.delete(ProviderId::Codex, "work").unwrap();
    assert!(vault.load(ProviderId::Codex, "work").unwrap().is_none());
    assert!(
        vault.load(ProviderId::Claude, "work").unwrap().is_some(),
        "deleting one provider's account must not touch the other's"
    );
    assert!(vault.load(ProviderId::Codex, "home").unwrap().is_some());
}

#[test]
fn a_label_from_a_phone_cannot_reach_outside_its_own_entry() {
    // The label becomes part of a keychain key. A label carrying the
    // separator could otherwise address another provider's entry.
    assert!(AccountVault::validate_label("claude:work").is_err());
    assert!(AccountVault::validate_label("").is_err());
    assert!(AccountVault::validate_label(&"a".repeat(61)).is_err());
    assert!(AccountVault::validate_label("../../etc/passwd").is_err());
    assert!(AccountVault::validate_label("ray.kang@jaco.live").is_ok());
    assert!(AccountVault::validate_label("Work Mac").is_ok());
}

#[test]
fn deleting_a_snapshot_that_was_never_saved_is_not_an_error() {
    let vault = AccountVault::new(Box::new(InMemorySecrets::default()));
    vault.delete(ProviderId::Claude, "never-existed").unwrap();
}

/// Exercises the real login keychain, which a headless test run has no
/// business touching — hence ignored by default.
///
///     cargo test --test credentials -- --ignored
#[test]
#[ignore = "writes to the developer's login keychain"]
fn the_real_keychain_round_trips_a_snapshot() {
    let keychain = Keychain;
    let service = "live.jaco.remoteai.selftest";
    let secret = br#"{"tokens":{"refresh_token":"rt.1.example"}}"#;

    keychain.put(service, "probe", secret).unwrap();
    assert_eq!(keychain.get(service, "probe").unwrap().unwrap(), secret);
    keychain.delete(service, "probe").unwrap();
    assert!(keychain.get(service, "probe").unwrap().is_none());
}

/// Whether the agent can read Claude's live credential without macOS asking
/// the person at the Mac to approve it.
///
/// The item was created by another program, and a keychain item can be
/// restricted to the applications on its access list. If reading it prompts,
/// every account operation stalls behind a dialog on the Mac — which is the
/// one thing this client is not allowed to cause. Ignored by default: it
/// depends on that Mac being signed in to Claude.
///
///     cargo test --test credentials -- --ignored the_agent_can_read
#[test]
#[ignore = "reads this Mac's live Claude credential"]
fn the_agent_can_read_claudes_live_credential_without_a_prompt() {
    let user = std::env::var("USER").expect("a login name");
    let claude = LiveCredential::claude(&user);
    let read = claude
        .read(&Keychain)
        .expect("reading the keychain must not fail");
    // The value is never printed, only measured.
    match read {
        Some(secret) => assert!(
            secret.len() > 64,
            "a credential should be longer than {} bytes",
            secret.len()
        ),
        None => eprintln!("this Mac is not signed in to Claude; nothing to read"),
    }
}
