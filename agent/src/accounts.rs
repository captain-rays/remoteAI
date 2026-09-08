//! Managing which account each provider is signed in as.
//!
//! This is the piece that makes more than one account usable: the CLIs each
//! hold exactly one credential, so the agent keeps snapshots (see
//! [`crate::credentials`]) and puts the wanted one back. Signing in is
//! delegated to the CLI's own flow (see [`crate::login`]) and relayed to the
//! phone.
//!
//! Every operation here changes the credential a CLI will use next, which is
//! why each one re-reads the CLI's own answer afterwards instead of assuming
//! it worked.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, broadcast};

use crate::auth::{LoginProbe, LoginState, ProviderLogin};
use crate::credentials::{AccountVault, LiveCredential};
use crate::login::{LoginOutcome, LoginProgress, LoginSession, logout_command};
use crate::protocol::{ConversationEvent, ProviderId};
use crate::store::Store;

/// Why an account operation could not be done.
///
/// A closed set with a stable code each, because the code is all that crosses
/// to the phone: a provider's own error text can carry prompt content and
/// stderr, and the wording a person reads is the app's to choose anyway. Every
/// variant names something the person can act on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AccountError {
    #[error("nothing is signed in, so there is nothing to save")]
    NothingSignedIn,
    #[error("that account's credential is no longer saved")]
    CredentialMissing,
    #[error("the restored credential was refused by the CLI")]
    CredentialRejected,
    #[error("that login is no longer running")]
    LoginNotRunning,
    #[error("that account name cannot be used")]
    InvalidLabel,
    #[error("the sign-in flow could not be started")]
    LoginNotStarted,
    #[error("the Mac could not complete that")]
    Failed,
}

impl AccountError {
    pub fn code(self) -> &'static str {
        match self {
            Self::NothingSignedIn => "nothing_signed_in",
            Self::CredentialMissing => "account_credential_missing",
            Self::CredentialRejected => "account_credential_rejected",
            Self::LoginNotRunning => "login_not_running",
            Self::InvalidLabel => "invalid_account_label",
            Self::LoginNotStarted => "login_not_started",
            Self::Failed => "account_operation_failed",
        }
    }
}

type Result<T> = std::result::Result<T, AccountError>;

/// One saved account as the phone lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountEntry {
    /// The name the person gave it.
    pub label: String,
    /// What the CLI called the account when it was saved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display: Option<String>,
    /// Whether this is the account the CLI is using now.
    pub is_current: bool,
    /// Whether the credential is still in the keychain. An entry can outlive
    /// its secret — the keychain item can be deleted from Keychain Access —
    /// and offering to switch to one that is gone would just fail.
    pub has_credential: bool,
}

/// Everything the accounts screen shows for one provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountsView {
    pub provider: ProviderId,
    pub accounts: Vec<AccountEntry>,
    pub login: ProviderLogin,
    /// Whether a login attempt is running for this provider right now.
    pub login_in_progress: bool,
    /// Why the last sign-in did not take, if one did not.
    ///
    /// Kept here rather than delivered only as an event, because a phone's
    /// socket lives for one request: an outcome that arrived while nothing
    /// was connected would otherwise be lost, and the accounts screen would
    /// have nothing to show but a login that silently stopped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_login_message: Option<String>,
}

/// The account operations for one provider.
pub struct AccountService {
    provider: ProviderId,
    /// The provider's CLI. Only ever run with the fixed argument lists in
    /// [`crate::login`].
    program: String,
    live: LiveCredential,
    vault: Arc<AccountVault>,
    store: Arc<Store>,
    probe: Arc<LoginProbe>,
    /// One login at a time: two flows racing would each replace the other's
    /// credential, and neither would be the one the person finished.
    session: Arc<Mutex<Option<Arc<LoginSession>>>>,
    /// Why the last sign-in failed, for a phone that asks after the fact.
    last_login_message: Arc<Mutex<Option<String>>>,
    events: broadcast::Sender<(ProviderId, ConversationEvent)>,
}

impl AccountService {
    pub fn new(
        provider: ProviderId,
        program: impl Into<String>,
        live: LiveCredential,
        vault: Arc<AccountVault>,
        store: Arc<Store>,
        probe: Arc<LoginProbe>,
        events: broadcast::Sender<(ProviderId, ConversationEvent)>,
    ) -> Self {
        Self {
            provider,
            program: program.into(),
            live,
            vault,
            store,
            probe,
            session: Arc::new(Mutex::new(None)),
            last_login_message: Arc::new(Mutex::new(None)),
            events,
        }
    }

    pub fn provider(&self) -> ProviderId {
        self.provider
    }

    pub async fn view(&self) -> Result<AccountsView> {
        let stored = self
            .store
            .provider_accounts(self.provider)
            .await
            .map_err(|_| AccountError::Failed)?;
        let login = self.probe.read().await;
        // Nothing tells us when a CLI loses its credential on its own — a
        // token expires, or someone signs out elsewhere — so the index's
        // "current" flag goes stale. The CLI's own answer decides: while it
        // says signed out, no saved account is in use. Showing the stale tick
        // would tell the reader there is nothing to do at the exact moment
        // tapping that account is the way back in.
        let anything_in_use = login.state == LoginState::LoggedIn;
        let mut accounts = Vec::with_capacity(stored.len());
        for account in stored {
            let has_credential = self
                .vault
                .load(self.provider, &account.label)
                .map_err(|_| AccountError::Failed)?
                .is_some();
            accounts.push(AccountEntry {
                label: account.label,
                display: account.display,
                is_current: account.is_current && anything_in_use,
                has_credential,
            });
        }
        Ok(AccountsView {
            provider: self.provider,
            accounts,
            login,
            login_in_progress: self.session.lock().await.is_some(),
            last_login_message: self.last_login_message.lock().await.clone(),
        })
    }

    /// Save whatever the CLI is signed in as now under `label`.
    ///
    /// This is how an account that was set up on the Mac becomes switchable
    /// from the phone, and it is deliberately explicit: the agent never
    /// snapshots a credential on its own.
    pub async fn save_current(&self, label: &str) -> Result<AccountsView> {
        AccountVault::validate_label(label).map_err(|_| AccountError::InvalidLabel)?;
        let secret = self
            .live
            .read(&crate::credentials::Keychain)
            .map_err(|_| AccountError::Failed)?
            .ok_or(AccountError::NothingSignedIn)?;
        let login = self.probe.read().await;
        self.vault
            .save(self.provider, label, &secret)
            .map_err(|_| AccountError::Failed)?;
        self.record(label, login.account.as_deref()).await?;
        self.view().await
    }

    /// Forget a saved account. The live credential is untouched: deleting the
    /// copy of the account you are using should not sign you out of it.
    pub async fn delete(&self, label: &str) -> Result<AccountsView> {
        AccountVault::validate_label(label).map_err(|_| AccountError::InvalidLabel)?;
        self.vault
            .delete(self.provider, label)
            .map_err(|_| AccountError::Failed)?;
        self.store
            .delete_provider_account(self.provider, label)
            .await
            .map_err(|_| AccountError::Failed)?;
        self.view().await
    }

    /// Make a saved account the one the CLI uses.
    pub async fn activate(&self, label: &str) -> Result<AccountsView> {
        AccountVault::validate_label(label).map_err(|_| AccountError::InvalidLabel)?;
        let wanted = self
            .vault
            .load(self.provider, label)
            .map_err(|_| AccountError::Failed)?
            .ok_or(AccountError::CredentialMissing)?;

        // Take a fresh copy of the account being left first. Both CLIs
        // refresh their tokens in place, so the snapshot taken when it was
        // saved is probably older than what is live now — without this,
        // switching away and back would restore a stale credential.
        self.snapshot_current_account().await;

        // Make room by removing the credential, not by running the CLI's
        // logout. A logout is entitled to revoke the token at the provider,
        // which would leave the snapshot just taken of the outgoing account
        // useless — switching away would quietly destroy the account being
        // left. Signing out is a separate, explicit act (see `logout`), and
        // only there is the CLI's own command the right thing.
        self.live
            .clear(&crate::credentials::Keychain)
            .map_err(|_| AccountError::Failed)?;
        self.live
            .write(&crate::credentials::Keychain, &wanted)
            .map_err(|_| AccountError::Failed)?;
        self.probe.forget().await;

        let login = self.probe.read().await;
        if login.state == LoginState::LoggedOut {
            return Err(AccountError::CredentialRejected);
        }
        self.record(label, login.account.as_deref()).await?;
        self.view().await
    }

    /// Note an account as saved and as the one in use.
    async fn record(&self, label: &str, display: Option<&str>) -> Result<()> {
        self.store
            .upsert_provider_account(self.provider, label, display)
            .await
            .map_err(|_| AccountError::Failed)?;
        self.store
            .set_current_provider_account(self.provider, Some(label))
            .await
            .map_err(|_| AccountError::Failed)
    }

    pub async fn logout(&self) -> Result<AccountsView> {
        self.snapshot_current_account().await;
        self.run_logout().await?;
        self.probe.forget().await;
        self.store
            .set_current_provider_account(self.provider, None)
            .await
            .map_err(|_| AccountError::Failed)?;
        self.view().await
    }

    /// Begin the CLI's login flow, relayed to the phone.
    ///
    /// If something is already signed in, it is signed out first: both CLIs
    /// treat login as a replacement, and doing it explicitly means the
    /// account being replaced is snapshotted before it goes.
    pub async fn start_login(&self, label: Option<String>) -> Result<LoginProgress> {
        if let Some(label) = label.as_deref() {
            AccountVault::validate_label(label).map_err(|_| AccountError::InvalidLabel)?;
        }
        let mut held = self.session.lock().await;
        if let Some(existing) = held.as_ref() {
            // Not an error: a phone that lost the reply, or a second phone,
            // should join the flow that is running rather than break it.
            return Ok(existing.progress());
        }

        if self.probe.read().await.state == LoginState::LoggedIn {
            // Same reasoning as `activate`: the account being replaced was
            // just snapshotted, and a CLI logout may revoke it at the
            // provider, so the credential is removed rather than logged out.
            self.snapshot_current_account().await;
            self.live
                .clear(&crate::credentials::Keychain)
                .map_err(|_| AccountError::Failed)?;
            self.probe.forget().await;
        }

        // A new attempt is not the place to keep the previous one's failure.
        *self.last_login_message.lock().await = None;
        let events = self.events.clone();
        let provider = self.provider;
        // The id is minted here, not inside the session: a login command
        // that exits immediately runs its exit handler before `start`
        // returns, and that handler has to know which session it is ending.
        let session_id = uuid::Uuid::new_v4().to_string();
        let session = Arc::new(
            LoginSession::start(
                session_id.clone(),
                provider,
                &self.program,
                label.clone(),
                move |progress| {
                    let _ = events.send((
                        provider,
                        ConversationEvent::ProviderLoginProgress(
                            serde_json::to_value(&progress).unwrap_or_default(),
                        ),
                    ));
                },
                self.exit_handler(session_id, label),
            )
            .map_err(|_| AccountError::LoginNotStarted)?,
        );
        let progress = session.progress();
        *held = Some(session.clone());
        drop(held);

        // A flow nobody finishes must not hold the provider's login slot for
        // the rest of the agent's life.
        let slot = self.session.clone();
        let watched = session.clone();
        tokio::spawn(async move {
            tokio::time::sleep(LoginSession::lifetime()).await;
            let mut held = slot.lock().await;
            if held
                .as_ref()
                .is_some_and(|current| current.id == watched.id)
            {
                watched.cancel();
                *held = None;
            }
        });
        Ok(progress)
    }

    /// What to do when the login command exits: check with the CLI whether it
    /// worked, file the credential, and tell the phone either way.
    fn exit_handler(
        &self,
        session_id: String,
        label: Option<String>,
    ) -> impl FnOnce(bool, String) + Send + 'static {
        let runtime = tokio::runtime::Handle::current();
        let provider = self.provider;
        let probe = self.probe.clone();
        let vault = self.vault.clone();
        let store = self.store.clone();
        let live = self.live.clone();
        let events = self.events.clone();
        let slot = self.session.clone();
        let last_message = self.last_login_message.clone();

        move |succeeded, tail| {
            runtime.spawn(async move {
                {
                    // Only this session releases the slot. A handler that
                    // fired before its own session was recorded must not
                    // clear a later one.
                    let mut held = slot.lock().await;
                    if held
                        .as_ref()
                        .is_some_and(|current| current.id == session_id)
                    {
                        *held = None;
                    }
                }
                probe.forget().await;
                let login = probe.read().await;
                // The CLI's exit status is a hint; whether a credential now
                // exists is the answer.
                let signed_in = login.state == LoginState::LoggedIn;
                if signed_in
                    && let Some(label) = label.as_deref()
                    && let Ok(Some(secret)) = live.read(&crate::credentials::Keychain)
                {
                    let _ = vault.save(provider, label, &secret);
                    let _ = store
                        .upsert_provider_account(provider, label, login.account.as_deref())
                        .await;
                    let _ = store
                        .set_current_provider_account(provider, Some(label))
                        .await;
                }
                let outcome = LoginOutcome {
                    conversation_id: crate::login::login_channel(provider),
                    session_id,
                    provider,
                    succeeded: signed_in,
                    message: (!signed_in).then(|| failure_reason(succeeded, &tail)),
                };
                *last_message.lock().await = outcome.message.clone();
                let _ = events.send((
                    provider,
                    ConversationEvent::ProviderLoginCompleted(
                        serde_json::to_value(&outcome).unwrap_or_default(),
                    ),
                ));
            });
        }
    }

    pub async fn send_login_line(&self, session_id: &str, line: &str) -> Result<()> {
        let held = self.session.lock().await;
        let session = held
            .as_ref()
            .filter(|session| session.id == session_id)
            .ok_or(AccountError::LoginNotRunning)?;
        session
            .send_line(line)
            .map_err(|_| AccountError::LoginNotRunning)
    }

    pub async fn cancel_login(&self, session_id: &str) -> Result<()> {
        let mut held = self.session.lock().await;
        if let Some(session) = held.as_ref().filter(|session| session.id == session_id) {
            session.cancel();
            *held = None;
        }
        Ok(())
    }

    pub async fn login_progress(&self) -> Option<LoginProgress> {
        self.session
            .lock()
            .await
            .as_ref()
            .map(|session| session.progress())
    }

    /// Refresh the snapshot of whichever account is current, so a token the
    /// CLI has renewed is not lost when it is replaced.
    async fn snapshot_current_account(&self) {
        let Ok(stored) = self.store.provider_accounts(self.provider).await else {
            return;
        };
        let Some(current) = stored.into_iter().find(|account| account.is_current) else {
            return;
        };
        if let Ok(Some(secret)) = self.live.read(&crate::credentials::Keychain) {
            let _ = self.vault.save(self.provider, &current.label, &secret);
        }
    }

    async fn run_logout(&self) -> Result<()> {
        let (program, args) = logout_command(self.provider, &self.program);
        let output = tokio::process::Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output()
            .await;
        // A CLI that cannot log itself out — or is not there — must not leave
        // the old credential in place, because the next login would silently
        // keep using it.
        if !output.is_ok_and(|output| output.status.success()) {
            self.live
                .clear(&crate::credentials::Keychain)
                .map_err(|_| AccountError::Failed)?;
        }
        Ok(())
    }
}

/// Why a login did not take, in the CLI's own last words.
fn failure_reason(exited_cleanly: bool, tail: &str) -> String {
    let last = tail
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    if last.is_empty() {
        if exited_cleanly {
            "the login flow finished without signing in".to_owned()
        } else {
            "the login flow stopped before signing in".to_owned()
        }
    } else {
        last.to_owned()
    }
}

/// The account services, one per provider.
#[derive(Default)]
pub struct AccountServices {
    services: HashMap<ProviderId, Arc<AccountService>>,
}

impl AccountServices {
    pub fn insert(&mut self, service: Arc<AccountService>) {
        self.services.insert(service.provider(), service);
    }

    pub fn get(&self, provider: ProviderId) -> Option<Arc<AccountService>> {
        self.services.get(&provider).cloned()
    }
}
