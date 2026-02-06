#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

JOBS=${POLL_JOBS:-4}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Recover tasks stuck in progress without an agent
STUCK_IDS=$(yq -r '.tasks[] | select(.status == "in_progress" and (.agent == null or .agent == "")) | .id' "$TASKS_PATH")
if [ -n "$STUCK_IDS" ]; then
  NOW=$(now_iso)
  export NOW
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    with_lock yq -i \
      "(.tasks[] | select(.id == $sid) | .status) = \"needs_review\" | \
       (.tasks[] | select(.id == $sid) | .last_error) = \"task stuck in_progress without agent\" | \
       (.tasks[] | select(.id == $sid) | .updated_at) = env(NOW)" \
      "$TASKS_PATH"
    append_history "$sid" "needs_review" "stuck in_progress without agent"
  done <<< "$STUCK_IDS"
fi

# Run all new/routed tasks in parallel
NEW_IDS=$(yq -r '.tasks[] | select(.status == "new" or .status == "routed") | .id' "$TASKS_PATH")
if [ -n "$NEW_IDS" ]; then
  printf '%s\n' "$NEW_IDS" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
fi

# Run retryable needs_review tasks
NOW_EPOCH=$(now_epoch)
RETRY_IDS=$(yq -r ".tasks[] | select(.status == \"needs_review\" and (.retry_at == null or .retry_at <= $NOW_EPOCH)) | .id" "$TASKS_PATH")
if [ -n "$RETRY_IDS" ]; then
  printf '%s\n' "$RETRY_IDS" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
fi

# Collect blocked parents ready to rejoin
READY_IDS=()
BLOCKED_IDS=$(yq -r '.tasks[] | select(.status == "blocked") | .id' "$TASKS_PATH")
if [ -n "$BLOCKED_IDS" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue

    CHILD_IDS=$(yq -r ".tasks[] | select(.id == $id) | .children[]?" "$TASKS_PATH")
    if [ -z "$CHILD_IDS" ]; then
      continue
    fi

    ALL_DONE=true
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      STATUS=$(yq -r ".tasks[] | select(.id == $cid) | .status" "$TASKS_PATH")
      if [ "$STATUS" != "done" ]; then
        ALL_DONE=false
        break
      fi
    done <<< "$CHILD_IDS"

    if [ "$ALL_DONE" = true ]; then
      READY_IDS+=("$id")
    fi
  done <<< "$BLOCKED_IDS"
fi

if [ ${#READY_IDS[@]} -gt 0 ]; then
  printf '%s\n' "${READY_IDS[@]}" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
fi
