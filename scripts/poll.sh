#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

JOBS=${POLL_JOBS:-4}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Run all new tasks in parallel
NEW_IDS=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH")
if [ -n "$NEW_IDS" ]; then
  printf '%s\n' "$NEW_IDS" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
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
