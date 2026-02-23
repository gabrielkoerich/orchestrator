#!/usr/bin/env bash
# task_attach.sh — Attach to a running agent's tmux session
# Usage: task_attach.sh <task_id>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  log_err "Usage: task_attach.sh <task_id>"
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
  log_err "The agent may have already finished. Check: orch task live"
  exit 1
fi

_SESSION_COUNT=$(printf '%s\n' "$_SESSIONS" | grep -c . || true)
if [ "$_SESSION_COUNT" -gt 1 ]; then
  log_err "Warning: multiple sessions found for task $TASK_ID — attaching to first ($SESSION)"
fi

log_err "Attaching to $SESSION (detach: Ctrl-B D)"
exec tmux attach-session -t "$SESSION"
