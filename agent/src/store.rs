use std::fs::{self, OpenOptions, Permissions};
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{ConnectOptions, Row, SqlitePool};

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
}

fn create_private_file(path: &Path) -> io::Result<()> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    fs::set_permissions(path, Permissions::from_mode(0o600))
}
