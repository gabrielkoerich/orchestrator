//! Job scheduler — replaces `jobs_tick.sh`.
//!
//! Reads job definitions from `jobs.yml`, checks cron schedules against
//! the current time, and creates tasks for due jobs. Handles catch-up
//! for missed schedules (capped at 24h).
//!
//! Job types:
//! - `task`: creates a GitHub Issue and lets the engine dispatch it
//! - `bash`: runs a shell command directly (no LLM)

use crate::backends::{ExternalBackend, ExternalId};
use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;

/// A scheduled job definition (from jobs.yml).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    #[serde(default = "default_job_type")]
    pub r#type: String,
    pub schedule: String,
    #[serde(default)]
    pub task: Option<TaskTemplate>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub dir: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub last_run: Option<String>,
    #[serde(default)]
    pub last_task_status: Option<String>,
    #[serde(default)]
    pub active_task_id: Option<String>,
}

/// Template for creating a task from a job.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskTemplate {
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub agent: Option<String>,
}

fn default_job_type() -> String {
    "task".to_string()
}

fn default_enabled() -> bool {
    true
}

/// Top-level jobs.yml structure.
#[derive(Debug, Serialize, Deserialize)]
pub struct JobsFile {
    #[serde(default)]
    pub jobs: Vec<Job>,
}

/// Load jobs from a YAML file.
pub fn load_jobs(path: &PathBuf) -> anyhow::Result<Vec<Job>> {
    if !path.exists() {
        return Ok(vec![]);
    }
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?;
    let file: JobsFile = serde_yaml::from_str(&content)
        .with_context(|| format!("parsing {}", path.display()))?;
    Ok(file.jobs)
}

/// Save jobs back to the YAML file (updates last_run, active_task_id, etc.).
pub fn save_jobs(path: &PathBuf, jobs: &[Job]) -> anyhow::Result<()> {
    let file = JobsFile {
        jobs: jobs.to_vec(),
    };
    let content = serde_yaml::to_string(&file)?;
    std::fs::write(path, content)
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Check all jobs and execute due ones.
pub async fn tick(
    jobs_path: &PathBuf,
    backend: &Arc<dyn ExternalBackend>,
) -> anyhow::Result<()> {
    let mut jobs = load_jobs(jobs_path)?;
    let mut changed = false;
    let now = chrono::Utc::now();

    for job in &mut jobs {
        if !job.enabled {
            continue;
        }

        // Check if schedule matches
        let is_due = match &job.last_run {
            Some(last) => crate::cron::check(&job.schedule, Some(last))?,
            None => crate::cron::check(&job.schedule, None)?,
        };

        if !is_due {
            continue;
        }

        // Check if previous task is still active
        if let Some(ref task_id) = job.active_task_id {
            let task = backend.get_task(&ExternalId(task_id.clone())).await;
            if let Ok(task) = task {
                let status = task.labels.iter().find(|l| l.starts_with("status:"));
                match status.map(|s| s.as_str()) {
                    Some("status:done") => {
                        // Previous task done, clear it
                        job.active_task_id = None;
                    }
                    Some(_) => {
                        // Previous task still active, skip
                        tracing::debug!(
                            job_id = job.id,
                            task_id,
                            "skipping: previous task still active"
                        );
                        continue;
                    }
                    None => {
                        // No status label, treat as active
                        continue;
                    }
                }
            }
        }

        tracing::info!(job_id = job.id, r#type = job.r#type, "job due, executing");

        // Set last_run BEFORE execution (prevents catch-up loops on restart)
        job.last_run = Some(now.format("%Y-%m-%dT%H:%M:%SZ").to_string());
        changed = true;

        match job.r#type.as_str() {
            "task" => {
                if let Some(ref template) = job.task {
                    let mut labels = template.labels.clone();
                    labels.push("scheduled".to_string());
                    labels.push(format!("job:{}", job.id));

                    if let Some(ref agent) = template.agent {
                        if !agent.is_empty() {
                            labels.push(format!("agent:{agent}"));
                        }
                    }

                    match backend
                        .create_task(&template.title, &template.body, &labels)
                        .await
                    {
                        Ok(ext_id) => {
                            tracing::info!(
                                job_id = job.id,
                                task_id = ext_id.0,
                                "created task"
                            );
                            job.active_task_id = Some(ext_id.0);
                            job.last_task_status = Some("new".to_string());
                        }
                        Err(e) => {
                            tracing::error!(job_id = job.id, ?e, "failed to create task");
                            job.last_task_status = Some("failed".to_string());
                        }
                    }
                }
            }
            "bash" => {
                if let Some(ref cmd) = job.command {
                    let dir = job.dir.as_deref().unwrap_or(".");
                    tracing::info!(job_id = job.id, cmd, dir, "running bash command");

                    let output = tokio::process::Command::new("bash")
                        .arg("-c")
                        .arg(cmd)
                        .current_dir(dir)
                        .output()
                        .await;

                    match output {
                        Ok(o) if o.status.success() => {
                            job.last_task_status = Some("done".to_string());
                        }
                        Ok(o) => {
                            let stderr = String::from_utf8_lossy(&o.stderr);
                            tracing::warn!(
                                job_id = job.id,
                                code = o.status.code(),
                                %stderr,
                                "bash command failed"
                            );
                            job.last_task_status = Some("failed".to_string());
                        }
                        Err(e) => {
                            tracing::error!(job_id = job.id, ?e, "bash command error");
                            job.last_task_status = Some("failed".to_string());
                        }
                    }
                }
            }
            other => {
                tracing::warn!(job_id = job.id, r#type = other, "unknown job type");
            }
        }
    }

    if changed {
        save_jobs(jobs_path, &jobs)?;
    }

    Ok(())
}
