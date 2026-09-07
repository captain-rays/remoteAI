use std::fs::{self, OpenOptions, Permissions};
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{ConnectOptions, Row, SqlitePool};

use crate::pairing::PairedDevice;

/// One saved account, as the phone lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredAccount {
    pub label: String,
    pub display: Option<String>,
    pub is_current: bool,
}

pub struct Store {
    pool: SqlitePool,
    database_path: PathBuf,
    private_key_path: PathBuf,
}

impl Store {
    pub async fn open(state_dir: &Path) -> anyhow::Result<Self> {
        fs::create_dir_all(state_dir)?;
        fs::set_permissions(state_dir, Permissions::from_mode(0o700))?;

        let private_key_path = state_dir.join("agent-private-key.pem");
        create_private_file(&private_key_path)?;
        let database_path = state_dir.join("remoteai.sqlite3");
        create_private_file(&database_path)?;

        let options = SqliteConnectOptions::new()
            .filename(&database_path)
            .create_if_missing(true)
            .disable_statement_logging();
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        fs::set_permissions(&database_path, Permissions::from_mode(0o600))?;

        Ok(Self {
            pool,
            database_path,
            private_key_path,
        })
    }

    pub fn database_path(&self) -> &Path {
        &self.database_path
    }

    pub fn private_key_path(&self) -> &Path {
        &self.private_key_path
    }

    /// The provider accounts this agent has snapshots for.
    ///
    /// Labels and display names only: the credentials are in the keychain.
    pub async fn provider_accounts(
        &self,
        provider: crate::protocol::ProviderId,
    ) -> anyhow::Result<Vec<StoredAccount>> {
        let rows = sqlx::query(
            "SELECT label, display, is_current FROM provider_accounts \
             WHERE provider = ?1 ORDER BY label",
        )
        .bind(crate::credentials::provider_slug(provider))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| StoredAccount {
                label: row.get::<String, _>(0),
                display: row.get::<Option<String>, _>(1),
                is_current: row.get::<i64, _>(2) != 0,
            })
            .collect())
    }

    pub async fn upsert_provider_account(
        &self,
        provider: crate::protocol::ProviderId,
        label: &str,
        display: Option<&str>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO provider_accounts (provider, label, display, created_at, is_current) \
             VALUES (?1, ?2, ?3, ?4, 0) \
             ON CONFLICT(provider, label) DO UPDATE SET display = excluded.display",
        )
        .bind(crate::credentials::provider_slug(provider))
        .bind(label)
        .bind(display)
        .bind(Utc::now().to_rfc3339())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_provider_account(
        &self,
        provider: crate::protocol::ProviderId,
        label: &str,
    ) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM provider_accounts WHERE provider = ?1 AND label = ?2")
            .bind(crate::credentials::provider_slug(provider))
            .bind(label)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Record which account a provider is signed in as. Exactly one account
    /// per provider can be current, so the previous one is cleared in the
    /// same statement pair.
    pub async fn set_current_provider_account(
        &self,
        provider: crate::protocol::ProviderId,
        label: Option<&str>,
    ) -> anyhow::Result<()> {
        let slug = crate::credentials::provider_slug(provider);
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE provider_accounts SET is_current = 0 WHERE provider = ?1")
            .bind(slug)
            .execute(&mut *transaction)
            .await?;
        if let Some(label) = label {
            sqlx::query(
                "UPDATE provider_accounts SET is_current = 1 \
                 WHERE provider = ?1 AND label = ?2",
            )
            .bind(slug)
            .bind(label)
            .execute(&mut *transaction)
            .await?;
        }
        transaction.commit().await?;
        Ok(())
    }

    pub async fn table_names(&self) -> anyhow::Result<Vec<String>> {
        let rows = sqlx::query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|row| row.get::<String, _>(0)).collect())
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Every device this Mac has paired, revoked ones included.
    ///
    /// Pairing is meant to be done once. Keeping the registry only in memory
    /// made every agent restart demand a fresh QR scan.
    pub async fn load_devices(&self) -> anyhow::Result<Vec<PairedDevice>> {
        let rows = sqlx::query("SELECT id, label, public_key, revoked_at FROM devices ORDER BY id")
            .fetch_all(&self.pool)
            .await?;
        rows.iter()
            .map(|row| {
                let revoked_at = row
                    .get::<Option<String>, _>("revoked_at")
                    .map(|value| {
                        DateTime::parse_from_rfc3339(&value).map(|at| at.with_timezone(&Utc))
                    })
                    .transpose()?;
                Ok(PairedDevice {
                    id: row.get::<String, _>("id"),
                    label: row.get::<String, _>("label"),
                    public_key: row.get::<Vec<u8>, _>("public_key"),
                    revoked_at,
                })
            })
            .collect()
    }

    pub async fn upsert_device(&self, device: &PairedDevice) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO devices (id, label, public_key, revoked_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
                 label = excluded.label,
                 public_key = excluded.public_key,
                 revoked_at = excluded.revoked_at",
        )
        .bind(&device.id)
        .bind(&device.label)
        .bind(&device.public_key)
        .bind(device.revoked_at.map(|at| at.to_rfc3339()))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn set_device_revoked(
        &self,
        device_id: &str,
        revoked_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        sqlx::query("UPDATE devices SET revoked_at = ?2 WHERE id = ?1")
            .bind(device_id)
            .bind(revoked_at.to_rfc3339())
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

fn create_private_file(path: &Path) -> io::Result<()> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    fs::set_permissions(path, Permissions::from_mode(0o600))
}
