#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_jobs_file

JOB_ID="$1"
if [ -z "$JOB_ID" ]; then
  echo "usage: jobs_info.sh JOB_ID" >&2
  exit 1
fi

JOB=$(yq -r ".jobs[] | select(.id == \"$JOB_ID\")" "$JOBS_PATH")
if [ -z "$JOB" ] || [ "$JOB" = "null" ]; then
  echo "Job '$JOB_ID' not found." >&2
  exit 1
fi

TYPE=$(printf '%s' "$JOB" | yq -r '.type // "task"')
SCHEDULE=$(printf '%s' "$JOB" | yq -r '.schedule')
ENABLED=$(printf '%s' "$JOB" | yq -r '.enabled')
LAST_RUN=$(printf '%s' "$JOB" | yq -r '.last_run // "-"')
LAST_STATUS=$(printf '%s' "$JOB" | yq -r '.last_task_status // "-"')
ACTIVE_TASK=$(printf '%s' "$JOB" | yq -r '.active_task_id // "-"')
DIR=$(printf '%s' "$JOB" | yq -r '.dir // "-"')

[ "$LAST_RUN" = "null" ] && LAST_RUN="-"
[ "$LAST_STATUS" = "null" ] && LAST_STATUS="-"
[ "$ACTIVE_TASK" = "null" ] && ACTIVE_TASK="-"

kv "ID" "$JOB_ID"
kv "Type" "$TYPE"
kv "Schedule" "$SCHEDULE"
kv "Enabled" "$ENABLED"
kv "Last run" "$LAST_RUN"
kv "Last status" "$LAST_STATUS"
kv "Active task" "$ACTIVE_TASK"
kv "Directory" "$DIR"

if [ "$TYPE" = "bash" ]; then
  COMMAND=$(printf '%s' "$JOB" | yq -r '.command // ""')
  section "Command"
  echo "$COMMAND"
else
  TITLE=$(printf '%s' "$JOB" | yq -r '.task.title // ""')
  BODY=$(printf '%s' "$JOB" | yq -r '.task.body // ""')
  LABELS=$(printf '%s' "$JOB" | yq -r '.task.labels // [] | join(", ")')
  AGENT=$(printf '%s' "$JOB" | yq -r '.task.agent // "-"')
  [ "$AGENT" = "null" ] && AGENT="(router decides)"

  section "Task"
  kv "Title" "$TITLE"
  kv "Agent" "$AGENT"
  kv "Labels" "$LABELS"

  if [ -n "$BODY" ] && [ "$BODY" != "null" ]; then
    section "Body"
    echo "$BODY"
  fi
fi
