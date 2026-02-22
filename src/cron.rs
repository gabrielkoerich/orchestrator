//! Cron expression matcher — replaces the Python `cron_match.py` script.
//!
//! Supports:
//! - Standard 5-field cron expressions
//! - `--since TIMESTAMP` mode: check if the schedule fired between a timestamp and now
//!
//! This eliminates the `python3` subprocess that v0 forks on every tick.

use anyhow::Context;
use chrono::{DateTime, Utc};
use cron::Schedule;
use std::str::FromStr;

/// Check if a cron expression matches now, or (with `since`) has matched
/// at any point between `since` and now.
///
/// Returns `true` if the cron fired, `false` otherwise.
pub fn check(expression: &str, since: Option<&str>) -> anyhow::Result<bool> {
    // cron crate expects 7-field expressions (sec min hour dom mon dow year)
    // We accept 5-field (min hour dom mon dow) and wrap with "0" seconds + "*" year
    let full_expr = format!("0 {expression} *");

    let schedule = Schedule::from_str(&full_expr)
        .with_context(|| format!("invalid cron expression: {expression}"))?;

    let now = Utc::now();

    match since {
        Some(since_str) => {
            let since_dt = parse_timestamp(since_str)
                .with_context(|| format!("invalid --since timestamp: {since_str}"))?;

            // Cap at 24 hours to prevent runaway catch-up
            let cap = now - chrono::Duration::hours(24);
            let effective_since = if since_dt < cap { cap } else { since_dt };

            // Check if any occurrence falls between since and now
            Ok(schedule
                .after(&effective_since)
                .take_while(|dt| *dt <= now)
                .next()
                .is_some())
        }
        None => {
            // Check if the schedule matches the current minute
            let prev = schedule.after(&(now - chrono::Duration::minutes(1))).next();
            match prev {
                Some(dt) => Ok(dt.minute() == now.minute() && dt.hour() == now.hour()),
                None => Ok(false),
            }
        }
    }
}

/// Parse a timestamp string (ISO 8601 or common formats).
fn parse_timestamp(s: &str) -> anyhow::Result<DateTime<Utc>> {
    // Try ISO 8601 first
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.with_timezone(&Utc));
    }
    // Try without timezone (assume UTC)
    if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
        return Ok(dt.and_utc());
    }
    if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        return Ok(dt.and_utc());
    }
    anyhow::bail!("unrecognized timestamp format: {s}")
}

use chrono::Timelike;
