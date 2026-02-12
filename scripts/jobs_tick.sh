#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
require_jq
init_jobs_file
init_tasks_file

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

JOB_COUNT=$(yq -r '.jobs | length' "$JOBS_PATH")
if [ "$JOB_COUNT" -eq 0 ]; then
  exit 0
fi

NOW_MINUTE=$(date -u +"%Y-%m-%dT%H:%MZ")
CREATED=0

for i in $(seq 0 $((JOB_COUNT - 1))); do
  ENABLED=$(yq -r ".jobs[$i].enabled" "$JOBS_PATH")
  if [ "$ENABLED" != "true" ]; then
    continue
  fi

  JOB_ID=$(yq -r ".jobs[$i].id" "$JOBS_PATH")
  SCHEDULE=$(yq -r ".jobs[$i].schedule" "$JOBS_PATH")
  ACTIVE_TASK_ID=$(yq -r ".jobs[$i].active_task_id // \"\"" "$JOBS_PATH")
  LAST_RUN=$(yq -r ".jobs[$i].last_run // \"\"" "$JOBS_PATH")

  # Check if active task is still in-flight
  if [ -n "$ACTIVE_TASK_ID" ] && [ "$ACTIVE_TASK_ID" != "null" ]; then
    TASK_STATUS=$(yq -r ".tasks[] | select(.id == $ACTIVE_TASK_ID) | .status // \"\"" "$TASKS_PATH" 2>/dev/null || true)

    if [ -z "$TASK_STATUS" ]; then
      # Task no longer exists — clear active_task_id
      echo "[jobs] job=$JOB_ID active task $ACTIVE_TASK_ID not found, clearing" >&2
      yq -i ".jobs[$i].active_task_id = null" "$JOBS_PATH"
      ACTIVE_TASK_ID=""
    elif [ "$TASK_STATUS" != "done" ]; then
      # Task still in-flight — skip this job
      continue
    else
      # Task is done — record status, clear active_task_id
      export TASK_STATUS
      yq -i ".jobs[$i].active_task_id = null | .jobs[$i].last_task_status = strenv(TASK_STATUS)" "$JOBS_PATH"
      ACTIVE_TASK_ID=""
    fi
  fi

  # Check if schedule matches current minute
  if ! python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE"; then
    continue
  fi

  # Prevent duplicate creation if tick runs multiple times in the same minute
  if [ -n "$LAST_RUN" ] && [ "$LAST_RUN" != "null" ]; then
    LAST_RUN_MINUTE=$(printf '%s' "$LAST_RUN" | cut -c1-16)
    NOW_MINUTE_CMP=$(date -u +"%Y-%m-%dT%H:%M")
    if [ "$LAST_RUN_MINUTE" = "$NOW_MINUTE_CMP" ]; then
      continue
    fi
  fi

  # Create task from job template
  JOB_TITLE=$(yq -r ".jobs[$i].task.title" "$JOBS_PATH")
  JOB_BODY=$(yq -r ".jobs[$i].task.body // \"\"" "$JOBS_PATH")
  JOB_LABELS=$(yq -r ".jobs[$i].task.labels // [] | join(\",\")" "$JOBS_PATH")
  JOB_AGENT=$(yq -r ".jobs[$i].task.agent // \"\"" "$JOBS_PATH")

  # Add job tracking labels
  if [ -n "$JOB_LABELS" ]; then
    JOB_LABELS="${JOB_LABELS},scheduled,job:${JOB_ID}"
  else
    JOB_LABELS="scheduled,job:${JOB_ID}"
  fi

  ADD_OUTPUT=$("${SCRIPT_DIR}/add_task.sh" "$JOB_TITLE" "$JOB_BODY" "$JOB_LABELS")
  NEW_TASK_ID=$(printf '%s' "$ADD_OUTPUT" | grep -oE '[0-9]+$')

  # Set agent if specified
  if [ -n "$JOB_AGENT" ] && [ "$JOB_AGENT" != "null" ]; then
    export JOB_AGENT
    with_lock yq -i \
      "(.tasks[] | select(.id == $NEW_TASK_ID) | .agent) = strenv(JOB_AGENT)" \
      "$TASKS_PATH"
  fi

  # Update job state
  NOW=$(now_iso)
  export NOW NEW_TASK_ID
  yq -i ".jobs[$i].last_run = strenv(NOW) | .jobs[$i].active_task_id = (env(NEW_TASK_ID) | tonumber)" "$JOBS_PATH"

  echo "[jobs] job=$JOB_ID created task $NEW_TASK_ID" >&2
  CREATED=$((CREATED + 1))
done

if [ "$CREATED" -gt 0 ]; then
  echo "[jobs] created $CREATED task(s)" >&2
fi
