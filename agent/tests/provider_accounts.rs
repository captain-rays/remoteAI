//! Switching a provider between accounts, and signing one in from the phone.
//!
//! Driven against a stand-in CLI that behaves the way the real ones do: it
//! answers a status question, writes a credential when a login succeeds, and
//! removes it on logout. That is the whole contract the agent depends on, and
//! using a stub keeps a test run from touching the developer's own logins.

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use remote_ai_agent::accounts::AccountService;
use remote_ai_agent::auth::{LoginProbe, LoginState};
use remote_ai_agent::credentials::{AccountVault, InMemorySecrets, LiveCredential};
use remote_ai_agent::protocol::{ConversationEvent, ProviderId};
use remote_ai_agent::store::Store;

struct Harness {
    service: Arc<AccountService>,
    credential: std::path::PathBuf,
    /// One line per `auth logout` the stand-in was asked to perform. Absent
    /// until the first one.
    logouts: std::path::PathBuf,
    events: tokio::sync::broadcast::Receiver<(ProviderId, ConversationEvent)>,
    _home: tempfile::TempDir,
}

impl Harness {
    fn logout_count(&self) -> usize {
        std::fs::read_to_string(&self.logouts)
            .map(|recorded| recorded.lines().count())
            .unwrap_or(0)
    }
}

/// A stand-in for `claude`: `auth status --json`, `auth login`, `auth logout`.
///
/// The credential path is written into the script rather than passed in the
/// environment, so tests running in parallel cannot see each other's.
async fn harness(signed_in_as: Option<&str>) -> Harness {
    let home = tempfile::tempdir().unwrap();
    let credential = home.path().join("credential");
    let logouts = home.path().join("logouts");
    if let Some(account) = signed_in_as {
        std::fs::write(&credential, account).unwrap();
    }
    let program = home.path().join("fake-claude");
    std::fs::write(
        &program,
        format!(
            "#!/bin/sh\n\
             CRED='{}'\n\
             LOGOUTS='{}'\n\
             case \"$1 $2\" in\n\
             'auth status')\n\
               if [ -f \"$CRED\" ]; then\n\
                 printf '{{\"loggedIn\":true,\"email\":\"%s\"}}\\n' \"$(cat \"$CRED\")\"\n\
               else\n\
                 printf '{{\"loggedIn\":false}}\\n'\n\
               fi ;;\n\
             'auth logout')\n\
               echo logout >> \"$LOGOUTS\"\n\
               rm -f \"$CRED\" ;;\n\
             'auth login')\n\
               printf 'Open this link to sign in\\n'\n\
               printf 'https://auth.example.com/device\\n'\n\
               printf 'Paste the code here: '\n\
               read code\n\
               if [ \"$code\" = 'GOOD-CODE' ]; then\n\
                 printf 'new@example.com' > \"$CRED\"\n\
                 printf '\\nSigned in\\n'\n\
               else\n\
                 printf '\\nThat code was rejected\\n'\n\
                 exit 1\n\
               fi ;;\n\
             esac\n",
            credential.display(),
            logouts.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();

    let store = Arc::new(Store::open(&home.path().join("state")).await.unwrap());
    let (events, receiver) = tokio::sync::broadcast::channel(64);
    let program = program.to_str().unwrap().to_owned();
    let service = Arc::new(AccountService::new(
        ProviderId::Claude,
        program.clone(),
        LiveCredential::File(credential.clone()),
        Arc::new(AccountVault::new(Box::new(InMemorySecrets::default()))),
        store,
        // No cached answers: several tests change the credential behind the
        // CLI's back, and a minute-old answer would be what they measured.
        Arc::new(LoginProbe::claude(program).with_cache_for(std::time::Duration::ZERO)),
        events,
    ));
    Harness {
        service,
        credential,
        logouts,
        events: receiver,
        _home: home,
    }
}

#[tokio::test]
async fn an_account_set_up_on_the_mac_can_be_saved_and_switched_back_to() {
    // The point of the whole feature: two accounts, one CLI that can only
    // hold one at a time.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;

    let view = service.view().await.unwrap();
    assert!(view.accounts.is_empty(), "nothing is saved until asked");
    assert_eq!(view.login.state, LoginState::LoggedIn);
    assert_eq!(view.login.account.as_deref(), Some("first@example.com"));

    let view = service.save_current("first").await.unwrap();
    assert_eq!(view.accounts.len(), 1);
    assert_eq!(view.accounts[0].label, "first");
    assert_eq!(view.accounts[0].display.as_deref(), Some("first@example.com"));
    assert!(view.accounts[0].is_current);
    assert!(view.accounts[0].has_credential);

    // Stand in for a second account being signed in on the Mac.
    std::fs::write(&harness.credential, "second@example.com").unwrap();
    let view = service.save_current("second").await.unwrap();
    assert_eq!(view.accounts.len(), 2);
    assert!(
        view.accounts.iter().filter(|account| account.is_current).count() == 1,
        "exactly one account is current"
    );
    assert!(
        view.accounts
            .iter()
            .find(|account| account.label == "second")
            .unwrap()
            .is_current
    );

    let view = service.activate("first").await.unwrap();
    assert_eq!(view.login.account.as_deref(), Some("first@example.com"));
    assert!(
        view.accounts
            .iter()
            .find(|account| account.label == "first")
            .unwrap()
            .is_current
    );
    assert_eq!(
        std::fs::read_to_string(&harness.credential).unwrap(),
        "first@example.com"
    );

    let view = service.activate("second").await.unwrap();
    assert_eq!(view.login.account.as_deref(), Some("second@example.com"));
}

#[tokio::test]
async fn switching_away_keeps_the_credential_the_cli_has_since_refreshed() {
    // Both CLIs renew their tokens in place. Without re-snapshotting on the
    // way out, switching away and back would restore the credential as it
    // was when saved — which by then may be expired.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;
    service.save_current("first").await.unwrap();
    service.save_current("second").await.unwrap();

    // The CLI refreshes the live credential in place.
    std::fs::write(&harness.credential, "second-refreshed@example.com").unwrap();

    service.activate("first").await.unwrap();
    let view = service.activate("second").await.unwrap();

    assert_eq!(
        view.login.account.as_deref(),
        Some("second-refreshed@example.com"),
        "the refreshed credential must be what comes back"
    );
}

#[tokio::test]
async fn signing_out_leaves_the_saved_accounts_switchable() {
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;
    service.save_current("first").await.unwrap();

    let view = service.logout().await.unwrap();
    assert_eq!(view.login.state, LoginState::LoggedOut);
    assert!(!harness.credential.exists(), "the CLI's credential is gone");
    assert_eq!(view.accounts.len(), 1, "the saved copy is still there");
    assert!(
        !view.accounts[0].is_current,
        "nothing is current while signed out"
    );

    let view = service.activate("first").await.unwrap();
    assert_eq!(view.login.state, LoginState::LoggedIn);
}

#[tokio::test]
async fn deleting_the_account_you_are_using_does_not_sign_you_out_of_it() {
    // Deleting a *copy* is housekeeping. Interpreting it as "sign me out"
    // would take the reader's working session away without being asked.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;
    service.save_current("first").await.unwrap();

    let view = service.delete("first").await.unwrap();
    assert!(view.accounts.is_empty());
    assert_eq!(view.login.state, LoginState::LoggedIn);
    assert!(harness.credential.exists());
}

#[tokio::test]
async fn saving_when_nothing_is_signed_in_says_so() {
    let harness = harness(None).await;
    let error = harness
        .service
        .save_current("work")
        .await
        .expect_err("there is nothing to save");
    assert!(
        error.to_string().contains("nothing is signed in"),
        "the reason has to be sayable on the phone: {error}"
    );
}

#[tokio::test]
async fn switching_to_an_account_whose_credential_is_gone_is_refused_clearly() {
    // A keychain item can be deleted from Keychain Access, leaving the entry
    // behind. Restoring nothing and reporting success would look like a
    // silent sign-out.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;
    service.save_current("first").await.unwrap();
    let view = service.view().await.unwrap();
    assert!(view.accounts[0].has_credential);

    let error = service
        .activate("missing")
        .await
        .expect_err("no such account");
    assert!(error.to_string().contains("no longer saved"), "{error}");
    assert_eq!(
        std::fs::read_to_string(&harness.credential).unwrap(),
        "first@example.com",
        "a refused switch leaves the working account alone"
    );
}

#[tokio::test]
async fn signing_in_from_the_phone_relays_the_flow_and_files_the_credential() {
    let mut harness = harness(None).await;
    let service = harness.service.clone();

    let progress = service
        .start_login(Some("new".to_owned()))
        .await
        .unwrap();
    assert_eq!(progress.conversation_id, "login:claude");

    // Wait for the CLI to get as far as asking for the code.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let session = loop {
        let current = service.login_progress().await.expect("a running login");
        if current.awaiting_input {
            assert_eq!(
                current.verification_url.as_deref(),
                Some("https://auth.example.com/device")
            );
            break current.session_id;
        }
        assert!(std::time::Instant::now() < deadline, "no prompt: {current:?}");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };

    service.send_login_line(&session, "GOOD-CODE").await.unwrap();

    // The phone learns the outcome from an event, not from a reply.
    let outcome = loop {
        let (provider, event) = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            harness.events.recv(),
        )
        .await
        .expect("an event")
        .expect("the channel stays open");
        assert_eq!(provider, ProviderId::Claude);
        if let ConversationEvent::ProviderLoginCompleted(payload) = event {
            break payload;
        }
    };
    assert_eq!(outcome["succeeded"], true);
    assert_eq!(outcome["conversationId"], "login:claude");

    let view = service.view().await.unwrap();
    assert_eq!(view.login.account.as_deref(), Some("new@example.com"));
    assert_eq!(view.accounts.len(), 1, "the new account was filed");
    assert_eq!(view.accounts[0].label, "new");
    assert!(view.accounts[0].has_credential, "and its credential kept");
    assert!(view.accounts[0].is_current);
    assert!(!view.login_in_progress, "the login slot is free again");
    assert_eq!(
        view.last_login_message, None,
        "a sign-in that worked leaves no complaint behind"
    );
}

#[tokio::test]
async fn a_rejected_code_is_reported_as_a_failed_login_with_the_clis_reason() {
    let mut harness = harness(None).await;
    let service = harness.service.clone();
    service.start_login(None).await.unwrap();

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let session = loop {
        let current = service.login_progress().await.expect("a running login");
        if current.awaiting_input {
            break current.session_id;
        }
        assert!(std::time::Instant::now() < deadline, "no prompt: {current:?}");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };
    service.send_login_line(&session, "WRONG").await.unwrap();

    let outcome = loop {
        let (_, event) = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            harness.events.recv(),
        )
        .await
        .expect("an event")
        .expect("the channel stays open");
        if let ConversationEvent::ProviderLoginCompleted(payload) = event {
            break payload;
        }
    };
    assert_eq!(outcome["succeeded"], false);
    assert_eq!(
        outcome["message"], "That code was rejected",
        "the CLI's own last words are what the phone shows"
    );

    let view = service.view().await.unwrap();
    assert_eq!(view.login.state, LoginState::LoggedOut);
    assert!(view.accounts.is_empty(), "a failed login files nothing");
    // And a phone that only asks afterwards still learns why: its socket
    // lives for one request, so the outcome event may have had nobody to
    // reach.
    assert_eq!(
        view.last_login_message.as_deref(),
        Some("That code was rejected")
    );
}

#[tokio::test]
async fn signing_in_while_signed_in_signs_out_first_and_keeps_the_old_account() {
    // Asked for explicitly: logging in as a different account has to log out
    // of the current one. Doing it here rather than leaving it to the CLI is
    // also what makes the outgoing account's credential get saved.
    let harness = harness(Some("first@example.com")).await;
    let service = harness.service.clone();
    service.save_current("first").await.unwrap();

    service.start_login(Some("second".to_owned())).await.unwrap();

    assert_eq!(
        service.view().await.unwrap().login.state,
        LoginState::LoggedOut,
        "the old credential is gone before the new flow starts"
    );

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let session = loop {
        let current = service.login_progress().await.expect("a running login");
        if current.awaiting_input {
            break current.session_id;
        }
        assert!(std::time::Instant::now() < deadline, "no prompt: {current:?}");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };
    service.send_login_line(&session, "GOOD-CODE").await.unwrap();

    // Wait for the *filing* to land, not merely for the new login to show:
    // the sign-in becomes visible a moment before the account it belongs to
    // has been written down, so waiting on the login would be waiting on the
    // wrong thing.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let view = service.view().await.unwrap();
        if view.accounts.len() == 2 {
            assert_eq!(view.login.account.as_deref(), Some("new@example.com"));
            break;
        }
        assert!(std::time::Instant::now() < deadline, "login did not finish");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }

    // And the account that was signed out of is still switchable.
    let view = service.activate("first").await.unwrap();
    assert_eq!(view.login.account.as_deref(), Some("first@example.com"));
}

#[tokio::test]
async fn a_second_request_joins_the_login_that_is_running() {
    // Two phones, or one phone that lost the reply. Starting a second flow
    // would replace the credential the first one is about to write.
    let harness = harness(None).await;
    let service = harness.service.clone();

    let first = service.start_login(None).await.unwrap();
    let second = service.start_login(None).await.unwrap();
    assert_eq!(first.session_id, second.session_id);

    service.cancel_login(&first.session_id).await.unwrap();
    assert!(!service.view().await.unwrap().login_in_progress);
}

#[tokio::test]
async fn input_for_a_login_that_has_ended_is_refused() {
    let harness = harness(None).await;
    let service = harness.service.clone();
    let progress = service.start_login(None).await.unwrap();
    service.cancel_login(&progress.session_id).await.unwrap();

    let error = service
        .send_login_line(&progress.session_id, "GOOD-CODE")
        .await
        .expect_err("nothing is listening");
    assert!(error.to_string().contains("no longer running"), "{error}");
}

#[tokio::test]
async fn switching_accounts_does_not_run_the_clis_logout() {
    // A logout is entitled to revoke the token at the provider. Doing one to
    // make room for another account would leave the snapshot of the account
    // being left useless — switching away would destroy it. Signing out is a
    // separate, explicit act, and only there is the CLI's own logout right.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;

    service.save_current("first").await.unwrap();
    service.save_current("second").await.unwrap();
    service.activate("first").await.unwrap();
    service.activate("second").await.unwrap();

    assert_eq!(
        harness.logout_count(),
        0,
        "switching accounts must not invoke the CLI's logout"
    );

    // Signing out, on the other hand, is exactly when it should.
    service.logout().await.unwrap();
    assert_eq!(
        harness.logout_count(),
        1,
        "an explicit sign-out goes through the CLI"
    );
}

/// The live write path: this Mac's real Claude CLI and real login keychain.
///
/// Everything above runs against a stand-in, which proves the logic but not
/// that this Mac will let the agent read the credential the CLI is using and
/// keep a copy in the keychain. Saving only reads the live credential, so it
/// cannot disturb the sign-in. Ignored by default — it needs this Mac to be
/// signed in to Claude, and it writes (then removes) one keychain item.
///
///     cargo test --test provider_accounts -- --ignored saving_this_macs
#[tokio::test]
#[ignore = "uses this Mac's real Claude CLI and login keychain"]
async fn saving_this_macs_real_claude_account_keeps_a_working_copy() {
    use remote_ai_agent::credentials::Keychain;

    let claude = match std::process::Command::new("which").arg("claude").output() {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_owned()
        }
        _ => {
            eprintln!("claude is not installed here; nothing to check");
            return;
        }
    };
    let user = std::env::var("USER").expect("a login name");
    let live = LiveCredential::claude(&user);
    let state = tempfile::tempdir().unwrap();
    let vault = Arc::new(AccountVault::keychain());
    let label = "remoteai-selftest";
    let service = AccountService::new(
        ProviderId::Claude,
        claude,
        live,
        vault.clone(),
        Arc::new(Store::open(state.path()).await.unwrap()),
        Arc::new(LoginProbe::claude(
            std::env::var("REMOTEAI_CLAUDE_BIN").unwrap_or_else(|_| "claude".into()),
        )),
        tokio::sync::broadcast::channel(8).0,
    );

    let before = service.view().await.unwrap();
    if before.login.state != LoginState::LoggedIn {
        eprintln!("this Mac is not signed in to Claude; nothing to save");
        return;
    }
    assert!(
        before.login.account.is_some(),
        "the CLI names the account it is signed in as"
    );

    let after = service.save_current(label).await.unwrap();
    let saved = after
        .accounts
        .iter()
        .find(|account| account.label == label)
        .expect("the account was filed");
    assert!(saved.is_current);
    assert!(
        saved.has_credential,
        "the copy is in this Mac's keychain and readable back"
    );
    assert_eq!(saved.display, before.login.account);

    // Leave the keychain as it was found.
    vault.delete(ProviderId::Claude, label).unwrap();
    assert!(vault.load(ProviderId::Claude, label).unwrap().is_none());
    assert_eq!(
        service.view().await.unwrap().login.state,
        LoginState::LoggedIn,
        "saving a copy never disturbs the sign-in"
    );
    let _ = Keychain;
}

#[tokio::test]
async fn an_account_stops_being_current_when_the_cli_signs_itself_out() {
    // The case this whole feature exists for: away from the Mac, Codex has
    // logged itself out, and the phone is the only way back in. Nothing tells
    // the agent that happened — a token expires, or the person signs out
    // somewhere else — so the "current" flag in its own index goes stale.
    //
    // Reporting the stale flag is worse than reporting nothing: the screen
    // says "not signed in" at the top and puts a tick next to a saved account
    // at the same time, and the tick is what tells the reader there is
    // nothing to do.
    let harness = harness(Some("first@example.com")).await;
    let service = &harness.service;
    service.save_current("first").await.unwrap();
    assert!(service.view().await.unwrap().accounts[0].is_current);

    // The CLI loses its credential without going through us.
    std::fs::remove_file(&harness.credential).unwrap();

    let view = service.view().await.unwrap();
    assert_eq!(view.login.state, LoginState::LoggedOut);
    assert_eq!(view.accounts.len(), 1, "the saved copy is still offered");
    assert!(
        view.accounts[0].has_credential,
        "and it still has a credential, so it is worth tapping"
    );
    assert!(
        !view.accounts[0].is_current,
        "nothing can be in use while the CLI is signed out"
    );

    // Switching to it is the way back, and it makes it current again.
    let view = service.activate("first").await.unwrap();
    assert_eq!(view.login.state, LoginState::LoggedIn);
    assert!(view.accounts[0].is_current);
}
