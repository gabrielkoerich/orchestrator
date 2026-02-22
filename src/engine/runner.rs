//! Task runner — delegates to `run_task.sh` for agent execution.
//!
//! Phase 2 approach: the Rust engine owns the loop and concurrency,
//! but `run_task.sh` still handles the complex agent invocation flow
//! (prompt building, git workflow, worktree management, response parsing).
//!
//! The runner spawns `run_task.sh $TASK_ID` as a subprocess and monitors it.
//! This lets us incrementally migrate — bash scripts work unchanged while
//! Rust takes over orchestration.

use anyhow::Context;
use std::path::PathBuf;
use tokio::process::Command;

/// Runs tasks by delegating to `run_task.sh`.
pub struct TaskRunner {
    /// Repository slug (owner/repo)
    repo: String,
    /// Path to the scripts directory
    scripts_dir: PathBuf,
    /// Path to the orchestrator home directory
    orch_home: PathBuf,
}

impl TaskRunner {
    pub fn new(repo: String) -> Self {
        let orch_home = dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join(".orchestrator");

        // Scripts live in libexec (brew) or the project dir
        let scripts_dir = std::env::var("ORCH_SCRIPTS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                // Try brew libexec first
                let brew_path = PathBuf::from("/opt/homebrew/Cellar")
                    .join("orchestrator");
                if brew_path.exists() {
                    // Find the latest version
                    if let Ok(entries) = std::fs::read_dir(&brew_path) {
                        if let Some(latest) = entries
                            .filter_map(|e| e.ok())
                            .max_by_key(|e| e.file_name())
                        {
                            return latest.path().join("libexec").join("scripts");
                        }
                    }
                }
                // Fall back to project dir
                orch_home.join("scripts")
            });

        Self {
            repo,
            scripts_dir,
            orch_home,
        }
    }

    /// Run a task by delegating to `run_task.sh`.
    ///
    /// This spawns the bash script and waits for it to complete.
    /// The script handles everything: routing, worktree, agent invocation,
    /// response parsing, git push, PR creation, and GitHub comments.
    pub async fn run(&self, task_id: &str) -> anyhow::Result<()> {
        let script = self.scripts_dir.join("run_task.sh");

        if !script.exists() {
            anyhow::bail!("run_task.sh not found at {}", script.display());
        }

        tracing::info!(task_id, script = %script.display(), "spawning run_task.sh");

        let output = Command::new("bash")
            .arg(&script)
            .arg(task_id)
            .env("ORCH_HOME", &self.orch_home)
            .env("GH_REPO", &self.repo)
            .env("PROJECT_DIR", self.project_dir()?)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .context("spawning run_task.sh")?
            .wait_with_output()
            .await
            .context("waiting for run_task.sh")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);

            // Log the output for debugging
            if !stdout.is_empty() {
                tracing::debug!(task_id, stdout = %stdout, "run_task.sh stdout");
            }
            if !stderr.is_empty() {
                tracing::warn!(task_id, stderr = %stderr, "run_task.sh stderr");
            }

            let code = output.status.code().unwrap_or(-1);
            anyhow::bail!("run_task.sh exited with code {code}: {stderr}");
        }

        Ok(())
    }

    /// Resolve the project directory for this repo.
    fn project_dir(&self) -> anyhow::Result<String> {
        // Check for bare clone
        let parts: Vec<&str> = self.repo.split('/').collect();
        if parts.len() == 2 {
            let bare = self.orch_home
                .join("projects")
                .join(parts[0])
                .join(format!("{}.git", parts[1]));
            if bare.exists() {
                return Ok(bare.to_string_lossy().to_string());
            }
        }

        // Check for local project
        let home = dirs::home_dir().unwrap_or_default();
        let local = home.join("Projects").join(parts.last().unwrap_or(&""));
        if local.exists() {
            return Ok(local.to_string_lossy().to_string());
        }

        // Fall back to current directory
        Ok(std::env::current_dir()?.to_string_lossy().to_string())
    }
}
