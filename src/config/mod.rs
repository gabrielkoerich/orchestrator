//! Config reader — loads YAML config files and resolves dot-separated keys.
//!
//! Reads `~/.orchestrator/config.yml` (global) and `.orchestrator.yml` (project).
//! Project config overrides global config for the same key.

use anyhow::Context;
use std::path::PathBuf;

/// Resolve the global config path: `~/.orchestrator/config.yml`
fn global_config_path() -> anyhow::Result<PathBuf> {
    let home = dirs::home_dir().context("cannot determine home directory")?;
    Ok(home.join(".orchestrator").join("config.yml"))
}

/// Get a config value by dot-separated key (e.g. "agents.claude.model").
///
/// Lookup order:
/// 1. `.orchestrator.yml` in the current directory (project config)
/// 2. `~/.orchestrator/config.yml` (global config)
///
/// Returns the first match as a string.
pub fn get(key: &str) -> anyhow::Result<String> {
    // Try project config first
    let project_path = PathBuf::from(".orchestrator.yml");
    if project_path.exists() {
        if let Ok(val) = resolve_key(&project_path, key) {
            return Ok(val);
        }
    }

    // Fall back to global config
    let global_path = global_config_path()?;
    if global_path.exists() {
        return resolve_key(&global_path, key);
    }

    anyhow::bail!("config key not found: {key}")
}

/// Resolve a dot-separated key from a YAML file.
fn resolve_key(path: &PathBuf, key: &str) -> anyhow::Result<String> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?;
    let root: serde_yaml::Value = serde_yaml::from_str(&content)
        .with_context(|| format!("parsing {}", path.display()))?;

    let mut current = &root;
    for part in key.split('.') {
        current = current
            .get(part)
            .with_context(|| format!("key not found: {key}"))?;
    }

    match current {
        serde_yaml::Value::String(s) => Ok(s.clone()),
        serde_yaml::Value::Number(n) => Ok(n.to_string()),
        serde_yaml::Value::Bool(b) => Ok(b.to_string()),
        serde_yaml::Value::Null => Ok(String::new()),
        _ => Ok(serde_yaml::to_string(current)?),
    }
}
