#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_jq

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

ensure_state_dir
JOBS_LOG="${STATE_DIR}/jobs.log"

job_log() {
  local msg="$(now_iso) $*"
  echo "$msg" >> "$JOBS_LOG"
  log_err "$@"
}

JOB_COUNT=$(db_enabled_job_count)
if [ "$JOB_COUNT" -eq 0 ]; then
  exit 0
fi

NOW_MINUTE=$(date -u +"%Y-%m-%dT%H:%MZ")
CREATED=0

while IFS=$'\x1f' read -r JOB_ID SCHEDULE JOB_TYPE JOB_CMD JOB_TITLE JOB_BODY JOB_LABELS JOB_AGENT JOB_DIR ACTIVE_TASK_ID LAST_RUN; do
  [ -n "$JOB_ID" ] || continue

  # Check if active task is still in-flight
  if [ -n "$ACTIVE_TASK_ID" ] && [ "$ACTIVE_TASK_ID" != "null" ]; then
    TASK_STATUS=$(db_task_field "$ACTIVE_TASK_ID" "status" 2>/dev/null || true)

    if [ -z "$TASK_STATUS" ]; then
      job_log "[jobs] job=$JOB_ID active task $ACTIVE_TASK_ID not found, clearing"
      db_job_set "$JOB_ID" "active_task_id" ""
      ACTIVE_TASK_ID=""
    elif [ "$TASK_STATUS" != "done" ]; then
      continue
    else
      db "UPDATE jobs SET active_task_id = NULL, last_task_status = '$(sql_escape "$TASK_STATUS")' WHERE id = '$(sql_escape "$JOB_ID")';"
      ACTIVE_TASK_ID=""
    fi
  fi

  # Schedule matching with catch-up for missed runs during downtime
  if [ -n "$LAST_RUN" ] && [ "$LAST_RUN" != "null" ]; then
    # Prevent duplicate creation if tick runs multiple times in the same minute
    LAST_RUN_MINUTE=$(printf '%s' "$LAST_RUN" | cut -c1-16)
    NOW_MINUTE_CMP=$(date -u +"%Y-%m-%dT%H:%M")
    if [ "$LAST_RUN_MINUTE" = "$NOW_MINUTE_CMP" ]; then
      continue
    fi

    if python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE"; then
      : # Current minute matches — proceed to execution
    elif python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE" --since "$LAST_RUN"; then
      job_log "[jobs] job=$JOB_ID catch-up: missed run since $LAST_RUN"
    else
      continue
    fi
  elif ! python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE"; then
    # No last_run and current minute doesn't match — skip
    continue
  fi

  if [ "$JOB_TYPE" = "bash" ]; then
    if [ -z "$JOB_CMD" ] || [ "$JOB_CMD" = "null" ]; then
      job_log "[jobs] job=$JOB_ID type=bash but no command, skipping"
      continue
    fi

    if [ -n "$JOB_DIR" ] && [ "$JOB_DIR" != "null" ] && [ ! -d "$JOB_DIR" ]; then
      job_log "[jobs] job=$JOB_ID invalid dir=$JOB_DIR, disabling job to prevent repeated failures"
      NOW=$(now_iso)
      db "UPDATE jobs SET enabled = 0, last_run = '$NOW', last_task_status = 'failed' WHERE id = '$(sql_escape "$JOB_ID")';"
      continue
    fi

    job_log "[jobs] job=$JOB_ID running bash command"
    BASH_RC=0
    BASH_OUTPUT=$(cd "${JOB_DIR:-.}" && bash -c "$JOB_CMD" 2>&1) || BASH_RC=$?

    NOW=$(now_iso)
    if [ "$BASH_RC" -eq 0 ]; then
      BASH_STATUS="done"
    else
      BASH_STATUS="failed"
    fi
    db "UPDATE jobs SET last_run = '$NOW', last_task_status = '$(sql_escape "$BASH_STATUS")' WHERE id = '$(sql_escape "$JOB_ID")';"

    job_log "[jobs] job=$JOB_ID bash exit=$BASH_RC status=$BASH_STATUS"
    if [ -n "$BASH_OUTPUT" ]; then
      job_log "[jobs] job=$JOB_ID output: $(printf '%.500s' "$BASH_OUTPUT")"
    fi
    continue
  fi

  # Task job: create a task for agent processing
  # Add job tracking labels
  if [ -n "$JOB_LABELS" ] && [ "$JOB_LABELS" != "null" ]; then
    JOB_LABELS="${JOB_LABELS},scheduled,job:${JOB_ID}"
  else
    JOB_LABELS="scheduled,job:${JOB_ID}"
  fi

  ADD_OUTPUT=$(PROJECT_DIR="$JOB_DIR" "${SCRIPT_DIR}/add_task.sh" "$JOB_TITLE" "$JOB_BODY" "$JOB_LABELS")
  NEW_TASK_ID=$(printf '%s' "$ADD_OUTPUT" | rg -o 'task [0-9]+' | rg -o '[0-9]+')

  # Set agent if specified
  if [ -n "$JOB_AGENT" ] && [ "$JOB_AGENT" != "null" ]; then
    db_task_set "$NEW_TASK_ID" "agent" "$JOB_AGENT"
  fi

  # Update job state
  NOW=$(now_iso)
  db "UPDATE jobs SET last_run = '$NOW', active_task_id = $NEW_TASK_ID WHERE id = '$(sql_escape "$JOB_ID")';"

  job_log "[jobs] job=$JOB_ID created task $NEW_TASK_ID"
  CREATED=$((CREATED + 1))
done < <(db_enabled_jobs)

if [ "$CREATED" -gt 0 ]; then
  job_log "[jobs] created $CREATED task(s)"
fi
