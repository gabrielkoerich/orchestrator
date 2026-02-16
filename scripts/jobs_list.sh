#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_jobs_file

JOB_COUNT=$(yq -r '.jobs | length' "$JOBS_PATH")
if [ "$JOB_COUNT" -eq 0 ]; then
  echo "No jobs configured. Add one with: orchestrator job add \"0 9 * * *\" \"Title\""
  exit 0
fi

{
  printf 'ID\tTYPE\tSCHEDULE\tENABLED\tSTATUS\tLAST RUN\n'
  for i in $(seq 0 $((JOB_COUNT - 1))); do
    JOB_ID=$(yq -r ".jobs[$i].id" "$JOBS_PATH")
    JOB_TYPE=$(yq -r ".jobs[$i].type // \"task\"" "$JOBS_PATH")
    SCHEDULE=$(yq -r ".jobs[$i].schedule" "$JOBS_PATH")
    ENABLED=$(yq -r ".jobs[$i].enabled" "$JOBS_PATH")
    LAST_RUN=$(yq -r ".jobs[$i].last_run // \"-\"" "$JOBS_PATH")
    LAST_STATUS=$(yq -r ".jobs[$i].last_task_status // \"-\"" "$JOBS_PATH")

    if [ "$LAST_RUN" = "null" ]; then LAST_RUN="-"; fi
    if [ "$LAST_STATUS" = "null" ]; then LAST_STATUS="-"; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$JOB_ID" "$JOB_TYPE" "$SCHEDULE" "$ENABLED" "$LAST_STATUS" "$LAST_RUN"
  done
} | column -t -s $'\t'
