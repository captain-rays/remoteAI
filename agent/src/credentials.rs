//! Moving provider credentials around so more than one account can be used.
//!
//! Neither CLI can hold two accounts at once: each has exactly one place it
//! keeps the credential it is using — a file for Codex, a keychain item for
//! Claude — and logging in replaces whatever was there. Switching accounts
//! therefore means keeping copies somewhere else and putting the wanted one
//! back.
//!
//! The copies live in the login keychain. It is the only store on this Mac
//! that is encrypted at rest and access-controlled, and these copies are
//! bearer tokens: anything on disk would be a downgrade from where the CLIs
//! keep them. Nothing here ever writes a credential to a file the agent owns,
//! logs one, or passes one as a command-line argument, where `ps` would show
//! it to every process on the machine.

use std::fs::{self, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::protocol::ProviderId;

/// The keychain service the agent keeps its account snapshots under.
pub const VAULT_SERVICE: &str = "live.jaco.remoteai.accounts";

/// Where a provider's CLI keeps the credential it is using right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveCredential {
    /// A file the CLI reads and rewrites, kept owner-only.
    File(PathBuf),
    /// A macOS generic password.
    Keychain { service: String, account: String },
}

impl LiveCredential {
    /// Claude Code keeps its credential in the login keychain, under the name
    /// of the user running it.
    pub fn claude(user: &str) -> Self {
        Self::Keychain {
            service: "Claude Code-credentials".to_owned(),
            account: user.to_owned(),
        }
    }

    /// Codex keeps its credential in `~/.codex/auth.json`.
    pub fn codex(home: &Path) -> Self {
        Self::File(home.join(".codex").join("auth.json"))
    }

    /// `None` means there is no credential there — the CLI is logged out.
    pub fn read(&self, keychain: &dyn SecretStore) -> anyhow::Result<Option<Vec<u8>>> {
        match self {
            Self::File(path) => match fs::read(path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error.into()),
            },
            Self::Keychain { service, account } => keychain.get(service, account),
        }
    }

    pub fn write(&self, keychain: &dyn SecretStore, secret: &[u8]) -> anyhow::Result<()> {
        match self {
            Self::File(path) => {
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent)?;
                    fs::set_permissions(parent, Permissions::from_mode(0o700))?;
                }
                // Written owner-only from the start rather than chmodded
                // afterwards: for the moment in between, the token would be
                // world-readable.
                let mut file = OpenOptions::new()
                    .create(true)
                    .truncate(true)
                    .write(true)
                    .mode(0o600)
                    .open(path)?;
                file.write_all(secret)?;
                file.sync_all()?;
                fs::set_permissions(path, Permissions::from_mode(0o600))?;
                Ok(())
            }
            Self::Keychain { service, account } => keychain.put(service, account, secret),
        }
    }

    pub fn clear(&self, keychain: &dyn SecretStore) -> anyhow::Result<()> {
        match self {
            Self::File(path) => match fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error.into()),
            },
            Self::Keychain { service, account } => keychain.delete(service, account),
        }
    }
}

/// Somewhere secrets can be kept by name. The keychain in production; a map
/// in tests, so a test run never touches the login keychain of whoever runs
/// it.
pub trait SecretStore: Send + Sync {
    fn get(&self, service: &str, account: &str) -> anyhow::Result<Option<Vec<u8>>>;
    fn put(&self, service: &str, account: &str, secret: &[u8]) -> anyhow::Result<()>;
    fn delete(&self, service: &str, account: &str) -> anyhow::Result<()>;
}

/// The macOS login keychain.
#[derive(Debug, Default, Clone, Copy)]
pub struct Keychain;

impl SecretStore for Keychain {
    fn get(&self, service: &str, account: &str) -> anyhow::Result<Option<Vec<u8>>> {
        match security_framework::passwords::get_generic_password(service, account) {
            Ok(secret) => Ok(Some(secret)),
            // -25300 is errSecItemNotFound: absence, not failure.
            Err(error) if error.code() == -25300 => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn put(&self, service: &str, account: &str, secret: &[u8]) -> anyhow::Result<()> {
        security_framework::passwords::set_generic_password(service, account, secret)?;
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> anyhow::Result<()> {
        match security_framework::passwords::delete_generic_password(service, account) {
            Ok(()) => Ok(()),
            Err(error) if error.code() == -25300 => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

/// The account snapshots this agent keeps.
pub struct AccountVault {
    secrets: Box<dyn SecretStore>,
    service: String,
}

impl AccountVault {
    pub fn new(secrets: Box<dyn SecretStore>) -> Self {
        Self {
            secrets,
            service: VAULT_SERVICE.to_owned(),
        }
    }

    pub fn keychain() -> Self {
        Self::new(Box::new(Keychain))
    }

    /// A label is part of a keychain key and is chosen on a phone, so it is
    /// constrained rather than trusted.
    pub fn validate_label(label: &str) -> anyhow::Result<()> {
        anyhow::ensure!(!label.is_empty(), "an account needs a name");
        anyhow::ensure!(label.chars().count() <= 60, "that name is too long");
        anyhow::ensure!(
            label.chars().all(|character| character.is_alphanumeric()
                || matches!(character, '-' | '_' | '.' | '@' | ' ')),
            "a name may use letters, digits, spaces and - _ . @"
        );
        Ok(())
    }

    fn key(provider: ProviderId, label: &str) -> String {
        format!("{}:{label}", provider_slug(provider))
    }

    pub fn save(&self, provider: ProviderId, label: &str, secret: &[u8]) -> anyhow::Result<()> {
        Self::validate_label(label)?;
        self.secrets
            .put(&self.service, &Self::key(provider, label), secret)
    }

    pub fn load(&self, provider: ProviderId, label: &str) -> anyhow::Result<Option<Vec<u8>>> {
        Self::validate_label(label)?;
        self.secrets.get(&self.service, &Self::key(provider, label))
    }

    pub fn delete(&self, provider: ProviderId, label: &str) -> anyhow::Result<()> {
        Self::validate_label(label)?;
        self.secrets
            .delete(&self.service, &Self::key(provider, label))
    }
}

pub fn provider_slug(provider: ProviderId) -> &'static str {
    match provider {
        ProviderId::Claude => "claude",
        ProviderId::Codex => "codex",
    }
}

/// A `SecretStore` that keeps everything in memory. For tests, and for a
/// machine with no usable keychain, where losing snapshots on restart is
/// better than refusing to run.
#[derive(Debug, Default)]
pub struct InMemorySecrets {
    entries: std::sync::Mutex<std::collections::HashMap<(String, String), Vec<u8>>>,
}

impl SecretStore for InMemorySecrets {
    fn get(&self, service: &str, account: &str) -> anyhow::Result<Option<Vec<u8>>> {
        Ok(self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&(service.to_owned(), account.to_owned()))
            .cloned())
    }

    fn put(&self, service: &str, account: &str, secret: &[u8]) -> anyhow::Result<()> {
        self.entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert((service.to_owned(), account.to_owned()), secret.to_vec());
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> anyhow::Result<()> {
        self.entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&(service.to_owned(), account.to_owned()));
        Ok(())
    }
}
