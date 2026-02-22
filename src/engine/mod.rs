//! Engine — the core orchestration loop.
//!
//! Replaces `serve.sh` + `poll.sh` + `jobs_tick.sh` with a single async loop.
//! The engine owns:
//! - The tick loop (poll for new tasks, check job schedules)
//! - The backend connection (GitHub Issues)
//! - The channel registry (all I/O surfaces)
//! - The transport layer (routes messages ↔ tmux sessions)
//!
//! All state transitions go through the engine. Channels and backends are
//! pluggable — the engine doesn't know which ones are active.

use crate::backends::github::GitHubBackend;
use crate::backends::ExternalBackend;
use crate::channels::ChannelRegistry;
use crate::channels::transport::Transport;
use crate::db::Db;
use std::sync::Arc;
use tokio::signal;

/// Start the orchestrator service.
///
/// This is the main entry point — called by `orch-core serve`.
pub async fn serve() -> anyhow::Result<()> {
    tracing::info!("orch-core engine starting");

    // Load config
    let repo = crate::config::get("repo")
        .unwrap_or_else(|_| "owner/repo".to_string());

    // Initialize backend
    let backend: Arc<dyn ExternalBackend> = Arc::new(GitHubBackend::new(repo));

    // Health check
    backend.health_check().await?;
    tracing::info!(backend = backend.name(), "backend connected");

    // Initialize internal database
    let db = Db::open(&crate::db::default_path()?)?;
    db.migrate().await?;
    tracing::info!("internal database ready");

    // Initialize transport
    let _transport = Arc::new(Transport::new());

    // Initialize channel registry
    let _channels = ChannelRegistry::new();

    // Main loop
    tracing::info!("entering main loop (10s tick)");
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));

    loop {
        tokio::select! {
            _ = interval.tick() => {
                if let Err(e) = tick(&backend, &db).await {
                    tracing::error!(?e, "tick failed");
                }
            }
            _ = signal::ctrl_c() => {
                tracing::info!("received SIGINT, shutting down");
                break;
            }
        }
    }

    tracing::info!("orch-core engine stopped");
    Ok(())
}

/// One tick of the main loop.
async fn tick(
    _backend: &Arc<dyn ExternalBackend>,
    _db: &Db,
) -> anyhow::Result<()> {
    // TODO: poll for new/routed tasks
    // TODO: check job schedules
    // TODO: detect stuck in_progress tasks
    // TODO: unblock parent tasks
    Ok(())
}
