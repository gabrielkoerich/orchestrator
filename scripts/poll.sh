#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

JOBS=${POLL_JOBS:-4}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Recover tasks stuck in_progress — either no agent assigned, or stale (no lock, updated too long ago)
STUCK_TIMEOUT=${STUCK_TIMEOUT:-$(config_get '.workflow.stuck_timeout // 1800')}
NOW_EPOCH=$(date +%s)
NOW=$(now_iso)
export NOW

if _use_sqlite; then
  # --- SQLite path (atomic, no file locking needed) ---

  # Stuck detection: in_progress without agent → needs_review
  IN_PROGRESS_IDS=$(db_task_ids_by_status "in_progress")
  if [ -n "$IN_PROGRESS_IDS" ]; then
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      TASK_LOCK="${LOCK_PATH}.task.${sid}"
      TASK_AGENT=$(db_task_field "$sid" "agent")

      if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
        log "[poll] task=$sid stuck in_progress without agent"
        db_task_update "$sid" status=needs_review "last_error=task stuck in_progress without agent"
        db_append_history "$sid" "needs_review" "stuck in_progress without agent"
        continue
      fi

      # Agent assigned but no lock held — agent process died
      if [ ! -d "$TASK_LOCK" ]; then
        UPDATED_AT=$(db_task_field "$sid" "updated_at")
        if [ -n "$UPDATED_AT" ] && [ "$UPDATED_AT" != "null" ]; then
          UPDATED_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
          ELAPSED=$((NOW_EPOCH - UPDATED_EPOCH))
          if [ "$ELAPSED" -ge "$STUCK_TIMEOUT" ]; then
            log "[poll] task=$sid stuck in_progress for ${ELAPSED}s (no lock held), recovering"
            db_task_update "$sid" status=new "last_error=recovered: stuck in_progress for ${ELAPSED}s"
            db_append_history "$sid" "new" "recovered from stuck in_progress (${ELAPSED}s, no lock)"
          fi
        fi
      fi
    done <<< "$IN_PROGRESS_IDS"
  fi

  # Check in_review tasks for merged PRs → mark done
  IN_REVIEW_IDS=$(db_task_ids_by_status "in_review")
  if [ -n "$IN_REVIEW_IDS" ] && command -v gh >/dev/null 2>&1; then
    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      BRANCH=$(db_task_field "$rid" "branch")
      TASK_DIR=$(db_task_field "$rid" "dir")
      WORKTREE=$(db_task_field "$rid" "worktree")
      CHECK_DIR="${WORKTREE:-${TASK_DIR:-.}}"

      if [ -n "$BRANCH" ] && [ "$BRANCH" != "null" ] && [ -d "$CHECK_DIR" ]; then
        PR_STATE=$(cd "$CHECK_DIR" && gh pr view "$BRANCH" --json state -q '.state' 2>/dev/null || true)
        if [ "$PR_STATE" = "MERGED" ]; then
          log "[poll] task=$rid PR merged (branch=$BRANCH), marking done"
          db_task_set "$rid" "status" "done"
          db_append_history "$rid" "done" "PR merged"
        fi
      fi
    done <<< "$IN_REVIEW_IDS"
  fi

  # Worktree janitor: clean up done tasks with worktrees
  DONE_WITH_WORKTREE=$(db "SELECT id, worktree, COALESCE(branch, ''), COALESCE(dir, '') FROM tasks WHERE status = 'done' AND worktree IS NOT NULL AND worktree != '';")
  if [ -n "$DONE_WITH_WORKTREE" ]; then
    while IFS=$'\t' read -r tid wt branch task_dir; do
      [ -n "$tid" ] || continue
      [ -n "$wt" ] || continue
      [ -d "$wt" ] || continue

      MAIN_DIR="${task_dir:-.}"
      if [ ! -d "$MAIN_DIR/.git" ] && [ ! -f "$MAIN_DIR/.git" ]; then
        MAIN_DIR=$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/.git$||' || true)
      fi
      [ -d "$MAIN_DIR" ] || continue

      log "[poll] task=$tid cleaning up worktree $wt (branch=$branch)"
      (cd "$MAIN_DIR" && git worktree remove --force "$wt" 2>/dev/null) || true
      if [ -n "$branch" ] && [ "$branch" != "null" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        (cd "$MAIN_DIR" && git branch -D "$branch" 2>/dev/null) || true
      fi

      db_task_update "$tid" worktree=NULL branch=NULL
      db_append_history "$tid" "done" "cleaned up worktree and branch"
    done <<< "$DONE_WITH_WORKTREE"
  fi

  # Run all new/routed tasks in parallel (skip tasks with no-agent label)
  # SQLite: use UNION for new + routed, exclude no-agent via subquery
  NEW_IDS=$(db_scalar "SELECT t.id FROM tasks t
    WHERE t.status IN ('new', 'routed')
      AND t.id NOT IN (SELECT task_id FROM task_labels WHERE label = 'no-agent')
    ORDER BY t.id;")
  if [ -n "$NEW_IDS" ]; then
    printf '%s\n' "$NEW_IDS" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
  fi

  # Collect blocked parents ready to rejoin (all children done)
  READY_IDS=$(db_scalar "SELECT t.id FROM tasks t
    WHERE t.status = 'blocked'
      AND (SELECT COUNT(*) FROM task_children tc WHERE tc.parent_id = t.id) > 0
      AND NOT EXISTS (
        SELECT 1 FROM task_children tc
        JOIN tasks c ON c.id = tc.child_id
        WHERE tc.parent_id = t.id AND c.status != 'done'
      )
    ORDER BY t.id;")
  if [ -n "$READY_IDS" ]; then
    printf '%s\n' "$READY_IDS" | xargs -n1 -P "$JOBS" -I{} "$SCRIPT_DIR/run_task.sh" "{}"
  fi

else
  # --- YAML path (legacy) ---
  require_yq

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
          UPDATED_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
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

  # Worktree janitor
  DONE_WITH_WORKTREE=$(yq -r '.tasks[] | select(.status == "done" and .worktree != null and .worktree != "") | [.id, .worktree, .branch, .dir // ""] | @tsv' "$TASKS_PATH")
  if [ -n "$DONE_WITH_WORKTREE" ]; then
    while IFS=$'\t' read -r tid wt branch task_dir; do
      [ -n "$tid" ] || continue
      [ -n "$wt" ] || continue
      [ -d "$wt" ] || continue

      MAIN_DIR="${task_dir:-.}"
      if [ ! -d "$MAIN_DIR/.git" ] && [ ! -f "$MAIN_DIR/.git" ]; then
        MAIN_DIR=$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/.git$||' || true)
      fi
      [ -d "$MAIN_DIR" ] || continue

      log "[poll] task=$tid cleaning up worktree $wt (branch=$branch)"
      (cd "$MAIN_DIR" && git worktree remove --force "$wt" 2>/dev/null) || true
      if [ -n "$branch" ] && [ "$branch" != "null" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        (cd "$MAIN_DIR" && git branch -D "$branch" 2>/dev/null) || true
      fi

      NOW=$(now_iso)
      export NOW
      with_lock yq -i \
        "(.tasks[] | select(.id == $tid) | .worktree) = null |
         (.tasks[] | select(.id == $tid) | .branch) = null |
         (.tasks[] | select(.id == $tid) | .updated_at) = strenv(NOW)" \
        "$TASKS_PATH"
      append_history "$tid" "done" "cleaned up worktree and branch"
    done <<< "$DONE_WITH_WORKTREE"
  fi

  # Run all new/routed tasks in parallel (skip tasks with no-agent label)
  NEW_IDS=$(yq -r '.tasks[] | select((.status == "new" or .status == "routed") and (.labels // [] | map(select(. == "no-agent")) | length == 0)) | .id' "$TASKS_PATH")
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
fi
