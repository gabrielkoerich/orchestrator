#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  log_err "Usage: retry_task.sh <task_id>"
  exit 1
fi

STATUS=$(db_task_field "$TASK_ID" "status")
if [ -z "$STATUS" ] || [ "$STATUS" = "null" ]; then
  log_err "[retry] task=$TASK_ID not found"
  exit 1
fi

if [ "$STATUS" = "new" ] || [ "$STATUS" = "routed" ] || [ "$STATUS" = "in_progress" ]; then
  log_err "[retry] task=$TASK_ID already $STATUS"
  exit 0
fi

# Warn about environment failures — retrying won't help without manual fix
LAST_ERROR=$(db_task_field "$TASK_ID" "last_error")
if is_env_failure_error "$LAST_ERROR"; then
  log_err "[retry] task=$TASK_ID WARNING: last failure was an environment error: $LAST_ERROR"
  log_err "[retry] task=$TASK_ID retrying anyway — ensure the tool is installed first"
fi

db_task_update "$TASK_ID" "status=new" "agent=NULL"
append_history "$TASK_ID" "new" "retried from $STATUS"
log "[retry] task=$TASK_ID reset from $STATUS to new"
