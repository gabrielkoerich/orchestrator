//! External backend abstraction — trait for issue trackers.
//!
//! GitHub Issues is the first implementation. The trait is designed so
//! Linear, Jira, GitLab, or any issue tracker can be swapped in later.

pub mod github;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// Opaque identifier from the external system (issue number, Linear ID, etc.)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalId(pub String);

/// A task as represented in the external system.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalTask {
    pub id: ExternalId,
    pub title: String,
    pub body: String,
    pub state: String,
    pub labels: Vec<String>,
    pub author: String,
    pub created_at: String,
    pub updated_at: String,
    pub url: String,
}

/// Task status values understood by all backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    New,
    Routed,
    InProgress,
    Done,
    Blocked,
    InReview,
    NeedsReview,
}

impl Status {
    pub fn as_label(&self) -> &'static str {
        match self {
            Self::New => "status:new",
            Self::Routed => "status:routed",
            Self::InProgress => "status:in_progress",
            Self::Done => "status:done",
            Self::Blocked => "status:blocked",
            Self::InReview => "status:in_review",
            Self::NeedsReview => "status:needs_review",
        }
    }
}

/// The core trait for external task backends.
///
/// Each implementation talks to a different issue tracker.
/// The engine calls these methods without knowing which backend is active.
#[async_trait]
pub trait ExternalBackend: Send + Sync {
    /// Human-readable name (e.g. "github", "linear", "jira")
    fn name(&self) -> &str;

    /// Create a task in the external system.
    async fn create_task(
        &self,
        title: &str,
        body: &str,
        labels: &[String],
    ) -> anyhow::Result<ExternalId>;

    /// Fetch a task by its external ID.
    async fn get_task(&self, id: &ExternalId) -> anyhow::Result<ExternalTask>;

    /// Update task status.
    async fn update_status(&self, id: &ExternalId, status: Status) -> anyhow::Result<()>;

    /// List tasks by status.
    async fn list_by_status(&self, status: Status) -> anyhow::Result<Vec<ExternalTask>>;

    /// Post a comment / activity note.
    async fn post_comment(&self, id: &ExternalId, body: &str) -> anyhow::Result<()>;

    /// Set metadata labels / tags.
    async fn set_labels(&self, id: &ExternalId, labels: &[String]) -> anyhow::Result<()>;

    /// Remove a label / tag.
    async fn remove_label(&self, id: &ExternalId, label: &str) -> anyhow::Result<()>;

    /// Check if connected and authenticated.
    async fn health_check(&self) -> anyhow::Result<()>;
}
