//! Agent response parser — normalizes JSON output from different agents.
//!
//! Each agent (Claude, Codex, OpenCode) returns a different JSON shape.
//! This module parses them all into a common `AgentResponse` struct.
//! Replaces `scripts/parse_response.sh` + `jq` pipelines.

use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::io::Read;

/// Normalized agent response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentResponse {
    pub status: String,
    pub summary: String,
    pub accomplished: Vec<String>,
    pub remaining: Vec<String>,
    pub files: Vec<String>,
    #[serde(default)]
    pub error: Option<String>,
}

/// Parse an agent response from a file path (or stdin if "-").
pub fn parse_and_print(path: &str) -> anyhow::Result<()> {
    let content = if path == "-" {
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .context("reading stdin")?;
        buf
    } else {
        std::fs::read_to_string(path)
            .with_context(|| format!("reading {path}"))?
    };

    let response = parse(&content)?;
    println!("{}", serde_json::to_string_pretty(&response)?);
    Ok(())
}

/// Parse raw agent output into a normalized response.
pub fn parse(raw: &str) -> anyhow::Result<AgentResponse> {
    // Try direct JSON parse first (Claude structured output)
    if let Ok(resp) = serde_json::from_str::<AgentResponse>(raw) {
        return Ok(resp);
    }

    // Try extracting JSON from markdown code blocks
    if let Some(json_str) = extract_json_block(raw) {
        if let Ok(resp) = serde_json::from_str::<AgentResponse>(&json_str) {
            return Ok(resp);
        }
    }

    // Try parsing as a generic JSON value and mapping fields
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) {
        return map_generic_response(&val);
    }

    // Fallback: treat entire content as summary
    Ok(AgentResponse {
        status: "done".to_string(),
        summary: raw.trim().to_string(),
        accomplished: vec![],
        remaining: vec![],
        files: vec![],
        error: None,
    })
}

/// Extract the first JSON code block from markdown.
fn extract_json_block(text: &str) -> Option<String> {
    let start = text.find("```json")?;
    let content_start = text[start..].find('\n')? + start + 1;
    let end = text[content_start..].find("```")? + content_start;
    Some(text[content_start..end].to_string())
}

/// Map a generic JSON object to AgentResponse.
fn map_generic_response(val: &serde_json::Value) -> anyhow::Result<AgentResponse> {
    let obj = val.as_object().context("expected JSON object")?;

    let status = obj
        .get("status")
        .or_else(|| obj.get("result"))
        .and_then(|v| v.as_str())
        .unwrap_or("done")
        .to_string();

    let summary = obj
        .get("summary")
        .or_else(|| obj.get("message"))
        .or_else(|| obj.get("output"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let accomplished = extract_string_array(obj.get("accomplished"));
    let remaining = extract_string_array(obj.get("remaining"));
    let files = extract_string_array(obj.get("files"));
    let error = obj.get("error").and_then(|v| v.as_str()).map(String::from);

    Ok(AgentResponse {
        status,
        summary,
        accomplished,
        remaining,
        files,
        error,
    })
}

fn extract_string_array(val: Option<&serde_json::Value>) -> Vec<String> {
    val.and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}
