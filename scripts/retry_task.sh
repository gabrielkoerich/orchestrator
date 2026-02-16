#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  log_err "Usage: retry_task.sh <task_id>"
  exit 1
fi

STATUS=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .status" "$TASKS_PATH")
if [ -z "$STATUS" ] || [ "$STATUS" = "null" ]; then
  log_err "[retry] task=$TASK_ID not found"
  exit 1
fi

if [ "$STATUS" = "new" ] || [ "$STATUS" = "routed" ] || [ "$STATUS" = "in_progress" ]; then
  log_err "[retry] task=$TASK_ID already $STATUS"
  exit 0
fi

NOW=$(now_iso)
export NOW

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = \"new\" |
   (.tasks[] | select(.id == $TASK_ID) | .agent) = null |
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

append_history "$TASK_ID" "new" "retried from $STATUS"
log "[retry] task=$TASK_ID reset from $STATUS to new"
