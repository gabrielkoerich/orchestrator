//! `gh` CLI wrapper — structured args in, serde out.
//!
//! All GitHub API calls go through `gh api`. Auth is handled by `gh`.
//! We build the command args in Rust and deserialize the JSON output via serde.

use super::types::{GitHubComment, GitHubIssue};
use tokio::process::Command;

pub struct GhCli;

impl GhCli {
    pub fn new() -> Self {
        Self
    }

    /// Run `gh api` with args and return raw JSON bytes.
    async fn api(&self, args: &[&str]) -> anyhow::Result<Vec<u8>> {
        let output = Command::new("gh").arg("api").args(args).output().await?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("gh api failed: {stderr}");
        }
        Ok(output.stdout)
    }

    /// Check `gh auth status`.
    pub async fn auth_status(&self) -> anyhow::Result<()> {
        let output = Command::new("gh").args(["auth", "status"]).output().await?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("gh auth failed: {stderr}");
        }
        Ok(())
    }

    /// Create a GitHub issue.
    pub async fn create_issue(
        &self,
        repo: &str,
        title: &str,
        body: &str,
        labels: &[String],
    ) -> anyhow::Result<GitHubIssue> {
        let endpoint = format!("repos/{repo}/issues");
        let title_field = format!("title={title}");
        let body_field = format!("body={body}");
        let mut args = vec![
            endpoint.as_str(),
            "-X",
            "POST",
            "-f",
            &title_field,
            "-f",
            &body_field,
        ];
        let label_args: Vec<String> = labels.iter().map(|l| format!("labels[]={l}")).collect();
        for la in &label_args {
            args.push("-f");
            args.push(la.as_str());
        }

        let json = self.api(&args).await?;
        Ok(serde_json::from_slice(&json)?)
    }

    /// Get a single issue.
    pub async fn get_issue(&self, repo: &str, number: &str) -> anyhow::Result<GitHubIssue> {
        let endpoint = format!("repos/{repo}/issues/{number}");
        let json = self.api(&[&endpoint]).await?;
        Ok(serde_json::from_slice(&json)?)
    }

    /// List issues filtered by a label.
    pub async fn list_issues(&self, repo: &str, label: &str) -> anyhow::Result<Vec<GitHubIssue>> {
        let endpoint = format!("repos/{repo}/issues");
        let labels_field = format!("labels={label}");
        let json = self
            .api(&[
                &endpoint,
                "-X",
                "GET",
                "-f",
                &labels_field,
                "-f",
                "state=open",
                "-f",
                "per_page=100",
            ])
            .await?;
        Ok(serde_json::from_slice(&json)?)
    }

    /// Add labels to an issue.
    pub async fn add_labels(
        &self,
        repo: &str,
        number: &str,
        labels: &[String],
    ) -> anyhow::Result<()> {
        let endpoint = format!("repos/{repo}/issues/{number}/labels");
        let mut args = vec![endpoint.as_str(), "-X", "POST"];
        let label_args: Vec<String> = labels.iter().map(|l| format!("labels[]={l}")).collect();
        for la in &label_args {
            args.push("-f");
            args.push(la.as_str());
        }
        self.api(&args).await?;
        Ok(())
    }

    /// Remove a label from an issue.
    ///
    /// Returns Ok even if the label doesn't exist (404 from GitHub).
    /// Logs warnings on other errors but does not propagate them — this
    /// prevents a failed removal from blocking the new label addition.
    pub async fn remove_label(&self, repo: &str, number: &str, label: &str) -> anyhow::Result<()> {
        let encoded = urlencoding::encode(label);
        let endpoint = format!("repos/{repo}/issues/{number}/labels/{encoded}");
        if let Err(e) = self.api(&[&endpoint, "-X", "DELETE"]).await {
            tracing::warn!(repo, number, label, ?e, "failed to remove label");
        }
        Ok(())
    }

    /// Add a comment to an issue.
    pub async fn add_comment(&self, repo: &str, number: &str, body: &str) -> anyhow::Result<()> {
        let endpoint = format!("repos/{repo}/issues/{number}/comments");
        let body_field = format!("body={body}");
        self.api(&[&endpoint, "-X", "POST", "-f", &body_field])
            .await?;
        Ok(())
    }

    /// List comments on an issue.
    pub async fn list_comments(
        &self,
        repo: &str,
        number: &str,
    ) -> anyhow::Result<Vec<GitHubComment>> {
        let endpoint = format!("repos/{repo}/issues/{number}/comments");
        let json = self.api(&[&endpoint]).await?;
        Ok(serde_json::from_slice(&json)?)
    }
}
