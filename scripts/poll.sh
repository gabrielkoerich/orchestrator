#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

JOBS=${POLL_JOBS:-4}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Recover tasks stuck in_progress — either no agent assigned, or stale (no lock, updated too long ago)
STUCK_TIMEOUT=${STUCK_TIMEOUT:-$(config_get '.workflow.stuck_timeout // 1800')}
NOW_EPOCH=$(date +%s)
NOW=$(now_iso)
export NOW

IN_PROGRESS_IDS=$(yq -r '.tasks[] | select(.status == "in_progress") | .id' "$TASKS_PATH")
if [ -n "$IN_PROGRESS_IDS" ]; then
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    TASK_LOCK="${LOCK_PATH}.task.${sid}"
    TASK_AGENT=$(yq -r ".tasks[] | select(.id == $sid) | .agent // \"\"" "$TASKS_PATH")

    # No agent assigned — definitely stuck
    if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
      log "[poll] task=$sid stuck in_progress without agent"
      with_lock yq -i \
        "(.tasks[] | select(.id == $sid) | .status) = \"needs_review\" | \
         (.tasks[] | select(.id == $sid) | .last_error) = \"task stuck in_progress without agent\" | \
         (.tasks[] | select(.id == $sid) | .updated_at) = strenv(NOW)" \
        "$TASKS_PATH"
      append_history "$sid" "needs_review" "stuck in_progress without agent"
      continue
    fi

    # Agent assigned but no lock held — agent process died without cleanup
    if [ ! -d "$TASK_LOCK" ]; then
      UPDATED_AT=$(yq -r ".tasks[] | select(.id == $sid) | .updated_at // \"\"" "$TASKS_PATH")
      if [ -n "$UPDATED_AT" ] && [ "$UPDATED_AT" != "null" ]; then
        UPDATED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
        ELAPSED=$((NOW_EPOCH - UPDATED_EPOCH))
        if [ "$ELAPSED" -ge "$STUCK_TIMEOUT" ]; then
          log "[poll] task=$sid stuck in_progress for ${ELAPSED}s (no lock held), recovering"
          with_lock yq -i \
            "(.tasks[] | select(.id == $sid) | .status) = \"new\" | \
             (.tasks[] | select(.id == $sid) | .last_error) = \"recovered: stuck in_progress for ${ELAPSED}s\" | \
             (.tasks[] | select(.id == $sid) | .updated_at) = strenv(NOW)" \
            "$TASKS_PATH"
          append_history "$sid" "new" "recovered from stuck in_progress (${ELAPSED}s, no lock)"
        fi
      fi
    fi
  done <<< "$IN_PROGRESS_IDS"
fi

# Check in_review tasks for merged PRs → mark done
IN_REVIEW_IDS=$(yq -r '.tasks[] | select(.status == "in_review") | .id' "$TASKS_PATH")
if [ -n "$IN_REVIEW_IDS" ] && command -v gh >/dev/null 2>&1; then
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    BRANCH=$(yq -r ".tasks[] | select(.id == $rid) | .branch // \"\"" "$TASKS_PATH")
    TASK_DIR=$(yq -r ".tasks[] | select(.id == $rid) | .dir // \"\"" "$TASKS_PATH")
    WORKTREE=$(yq -r ".tasks[] | select(.id == $rid) | .worktree // \"\"" "$TASKS_PATH")
    CHECK_DIR="${WORKTREE:-${TASK_DIR:-.}}"

    if [ -n "$BRANCH" ] && [ "$BRANCH" != "null" ] && [ -d "$CHECK_DIR" ]; then
      PR_STATE=$(cd "$CHECK_DIR" && gh pr view "$BRANCH" --json state -q '.state' 2>/dev/null || true)
      if [ "$PR_STATE" = "MERGED" ]; then
        log "[poll] task=$rid PR merged (branch=$BRANCH), marking done"
        NOW=$(now_iso)
        export NOW
        with_lock yq -i \
          "(.tasks[] | select(.id == $rid) | .status) = \"done\" | \
           (.tasks[] | select(.id == $rid) | .updated_at) = strenv(NOW)" \
          "$TASKS_PATH"
        append_history "$rid" "done" "PR merged"
      fi
    fi
  done <<< "$IN_REVIEW_IDS"
fi

# Run all new/routed tasks in parallel
NEW_IDS=$(yq -r '.tasks[] | select(.status == "new" or .status == "routed") | .id' "$TASKS_PATH")
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
