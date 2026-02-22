//! SQLite database — internal task store.
//!
//! Internal tasks (cron jobs, mention handlers, maintenance) live here.
//! External tasks live in GitHub Issues (via the `backends` module).
//! No bidirectional sync — each storage is authoritative for its domain.

use anyhow::Context;
use rusqlite::Connection;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

/// Default database path: `~/.orchestrator/orchestrator.db`
pub fn default_path() -> anyhow::Result<PathBuf> {
    let home = dirs::home_dir().context("cannot determine home directory")?;
    let dir = home.join(".orchestrator");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("orchestrator.db"))
}

/// Database handle with async-safe locking.
pub struct Db {
    conn: Arc<Mutex<Connection>>,
}

impl Db {
    /// Open (or create) the database at the given path.
    pub fn open(path: &PathBuf) -> anyhow::Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("opening database: {}", path.display()))?;

        // WAL mode for concurrent reads
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Open an in-memory database (for testing).
    pub fn open_memory() -> anyhow::Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Run schema migrations.
    pub async fn migrate(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().await;
        conn.execute_batch(SCHEMA)?;
        Ok(())
    }

    /// Get a reference to the connection (for running queries).
    pub async fn conn(&self) -> tokio::sync::MutexGuard<'_, Connection> {
        self.conn.lock().await
    }
}

/// Internal database schema for jobs and internal tasks.
const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS internal_tasks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    body        TEXT DEFAULT '',
    status      TEXT DEFAULT 'new',
    source      TEXT NOT NULL,  -- 'cron', 'mention', 'manual'
    source_id   TEXT DEFAULT '', -- job ID, mention thread, etc.
    created_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS jobs (
    id          TEXT PRIMARY KEY,
    schedule    TEXT NOT NULL,
    type        TEXT NOT NULL DEFAULT 'task',
    command     TEXT DEFAULT '',
    task_title  TEXT DEFAULT '',
    task_body   TEXT DEFAULT '',
    enabled     INTEGER DEFAULT 1,
    last_run    TEXT DEFAULT '',
    last_status TEXT DEFAULT '',
    created_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_internal_tasks_status ON internal_tasks(status);
CREATE INDEX IF NOT EXISTS idx_internal_tasks_source ON internal_tasks(source);
CREATE INDEX IF NOT EXISTS idx_jobs_enabled ON jobs(enabled);
"#;
