#!/usr/bin/env bash
# task_kill.sh — Kill a running agent tmux session
# Usage: task_kill.sh <task_id>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  log_err "Usage: task_kill.sh <task_id>"
  exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
  log_err "tmux is not installed"
  exit 1
fi

# Session names include project: orch-{project}-{task_id}. Search by task ID suffix.
_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
  | grep -E "^orch-.*-${TASK_ID}$" || true)
SESSION=$(printf '%s' "$_SESSIONS" | head -1)

if [ -z "$SESSION" ]; then
  log_err "No active tmux session for task $TASK_ID"
  exit 1
fi

_SESSION_COUNT=$(printf '%s\n' "$_SESSIONS" | grep -c . || true)
if [ "$_SESSION_COUNT" -gt 1 ]; then
  log_err "Warning: multiple sessions found for task $TASK_ID — killing first ($SESSION)"
fi

log "Killing tmux session $SESSION for task $TASK_ID"
tmux kill-session -t "$SESSION"

# Mark task as needs_review since it was manually killed
CURRENT_STATUS=$(db_task_field "$TASK_ID" "status" 2>/dev/null || true)
if [ "$CURRENT_STATUS" = "in_progress" ]; then
  db_task_update "$TASK_ID" "status=needs_review" "last_error=agent session killed manually"
  db_append_history "$TASK_ID" "needs_review" "tmux session killed by user"
  log "Task $TASK_ID marked as needs_review"
fi
