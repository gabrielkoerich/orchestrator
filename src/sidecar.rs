//! Sidecar file management — JSON metadata files alongside tasks.
//!
//! Each task gets a `.orchestrator/{task_id}.json` sidecar file that stores
//! runtime metadata (model, prompt hash, timing, token counts, etc.).
//! This is the authoritative source for data that doesn't belong in GitHub labels.

use anyhow::Context;
use serde_json::Value;
use std::path::PathBuf;

/// Get the sidecar directory path.
fn sidecar_dir() -> anyhow::Result<PathBuf> {
    let home = dirs::home_dir().context("cannot determine home directory")?;
    let dir = home.join(".orchestrator").join(".orchestrator");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Get the path to a task's sidecar file.
fn sidecar_path(task_id: &str) -> anyhow::Result<PathBuf> {
    Ok(sidecar_dir()?.join(format!("{task_id}.json")))
}

/// Read a field from a sidecar file.
pub fn get(task_id: &str, field: &str) -> anyhow::Result<String> {
    let path = sidecar_path(task_id)?;
    let content = std::fs::read_to_string(&path)
        .with_context(|| format!("reading sidecar: {}", path.display()))?;
    let obj: Value = serde_json::from_str(&content)?;

    let val = obj
        .get(field)
        .with_context(|| format!("field not found: {field}"))?;

    match val {
        Value::String(s) => Ok(s.clone()),
        Value::Number(n) => Ok(n.to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Null => Ok(String::new()),
        _ => Ok(serde_json::to_string(val)?),
    }
}

/// Set one or more fields in a sidecar file.
///
/// Each entry in `fields` is "key=value" format.
pub fn set(task_id: &str, fields: &[String]) -> anyhow::Result<()> {
    let path = sidecar_path(task_id)?;

    // Load existing or create new
    let mut obj: serde_json::Map<String, Value> = if path.exists() {
        let content = std::fs::read_to_string(&path)?;
        serde_json::from_str(&content)?
    } else {
        serde_json::Map::new()
    };

    // Apply field updates
    for field in fields {
        let (key, value) = field
            .split_once('=')
            .with_context(|| format!("invalid field format (expected key=value): {field}"))?;
        obj.insert(key.to_string(), Value::String(value.to_string()));
    }

    // Write back
    let content = serde_json::to_string_pretty(&Value::Object(obj))?;
    std::fs::write(&path, content)?;
    Ok(())
}
