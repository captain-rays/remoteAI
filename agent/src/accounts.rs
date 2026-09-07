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
            events,
        }
    }

    pub fn provider(&self) -> ProviderId {
        self.provider
    }

    pub async fn view(&self) -> anyhow::Result<AccountsView> {
        let stored = self.store.provider_accounts(self.provider).await?;
        let mut accounts = Vec::with_capacity(stored.len());
        for account in stored {
            let has_credential = self
                .vault
                .load(self.provider, &account.label)?
                .is_some();
            accounts.push(AccountEntry {
                label: account.label,
                display: account.display,
                is_current: account.is_current,
                has_credential,
            });
        }
        Ok(AccountsView {
            provider: self.provider,
            accounts,
            login: self.probe.read().await,
            login_in_progress: self.session.lock().await.is_some(),
        })
    }

    /// Save whatever the CLI is signed in as now under `label`.
    ///
    /// This is how an account that was set up on the Mac becomes switchable
    /// from the phone, and it is deliberately explicit: the agent never
    /// snapshots a credential on its own.
    pub async fn save_current(&self, label: &str) -> anyhow::Result<AccountsView> {
        AccountVault::validate_label(label)?;
        let secret = self
            .live
            .read(&crate::credentials::Keychain)?
            .ok_or_else(|| anyhow::anyhow!("nothing is signed in, so there is nothing to save"))?;
        let login = self.probe.read().await;
        self.vault.save(self.provider, label, &secret)?;
        self.store
            .upsert_provider_account(self.provider, label, login.account.as_deref())
            .await?;
        self.store
            .set_current_provider_account(self.provider, Some(label))
            .await?;
        self.view().await
    }

    /// Forget a saved account. The live credential is untouched: deleting the
    /// copy of the account you are using should not sign you out of it.
    pub async fn delete(&self, label: &str) -> anyhow::Result<AccountsView> {
        AccountVault::validate_label(label)?;
        self.vault.delete(self.provider, label)?;
        self.store
            .delete_provider_account(self.provider, label)
            .await?;
        self.view().await
    }

    /// Make a saved account the one the CLI uses.
    pub async fn activate(&self, label: &str) -> anyhow::Result<AccountsView> {
        AccountVault::validate_label(label)?;
        let wanted = self
            .vault
            .load(self.provider, label)?
            .ok_or_else(|| anyhow::anyhow!("that account's credential is no longer saved"))?;

        // Take a fresh copy of the account being left first. Both CLIs
        // refresh their tokens in place, so the snapshot taken when it was
        // saved is probably older than what is live now — without this,
        // switching away and back would restore a stale credential.
        self.snapshot_current_account().await;

        // Log out through the CLI rather than by deleting its credential, so
        // whatever else it keeps alongside is dealt with too.
        self.run_logout().await?;
        self.live.write(&crate::credentials::Keychain, &wanted)?;
        self.probe.forget().await;

        let login = self.probe.read().await;
        anyhow::ensure!(
            login.state != LoginState::LoggedOut,
            "that account's credential was restored but the CLI rejected it; sign in again"
        );
        self.store
            .upsert_provider_account(self.provider, label, login.account.as_deref())
            .await?;
        self.store
            .set_current_provider_account(self.provider, Some(label))
            .await?;
        self.view().await
    }

    pub async fn logout(&self) -> anyhow::Result<AccountsView> {
        self.snapshot_current_account().await;
        self.run_logout().await?;
        self.probe.forget().await;
        self.store
            .set_current_provider_account(self.provider, None)
            .await?;
        self.view().await
    }

    /// Begin the CLI's login flow, relayed to the phone.
    ///
    /// If something is already signed in, it is signed out first: both CLIs
    /// treat login as a replacement, and doing it explicitly means the
    /// account being replaced is snapshotted before it goes.
    pub async fn start_login(&self, label: Option<String>) -> anyhow::Result<LoginProgress> {
        if let Some(label) = label.as_deref() {
            AccountVault::validate_label(label)?;
        }
        let mut held = self.session.lock().await;
        if let Some(existing) = held.as_ref() {
            // Not an error: a phone that lost the reply, or a second phone,
            // should join the flow that is running rather than break it.
            return Ok(existing.progress());
        }

        if self.probe.read().await.state == LoginState::LoggedIn {
            self.snapshot_current_account().await;
            self.run_logout().await?;
            self.probe.forget().await;
        }

        let events = self.events.clone();
        let provider = self.provider;
        // The id is minted here, not inside the session: a login command
        // that exits immediately runs its exit handler before `start`
        // returns, and that handler has to know which session it is ending.
        let session_id = uuid::Uuid::new_v4().to_string();
        let session = Arc::new(LoginSession::start(
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
        )?);
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
            if held.as_ref().is_some_and(|current| current.id == watched.id) {
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
                let _ = events.send((
                    provider,
                    ConversationEvent::ProviderLoginCompleted(
                        serde_json::to_value(&outcome).unwrap_or_default(),
                    ),
                ));
            });
        }
    }

    pub async fn send_login_line(&self, session_id: &str, line: &str) -> anyhow::Result<()> {
        let held = self.session.lock().await;
        let session = held
            .as_ref()
            .filter(|session| session.id == session_id)
            .ok_or_else(|| anyhow::anyhow!("that login is no longer running"))?;
        session.send_line(line)
    }

    pub async fn cancel_login(&self, session_id: &str) -> anyhow::Result<()> {
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

    async fn run_logout(&self) -> anyhow::Result<()> {
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
            self.live.clear(&crate::credentials::Keychain)?;
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
