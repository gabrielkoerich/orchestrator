#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_jobs_file

JOB_COUNT=$(yq -r '.jobs | length' "$JOBS_PATH")
if [ "$JOB_COUNT" -eq 0 ]; then
  echo "No jobs configured. Add one with: just jobs-add \"0 9 * * *\" \"Title\" \"Body\""
  exit 0
fi

printf '%-20s %-18s %-8s %-8s %-24s %s\n' "ID" "SCHEDULE" "ENABLED" "STATUS" "LAST RUN" "ACTIVE TASK"
printf '%-20s %-18s %-8s %-8s %-24s %s\n' "---" "---" "---" "---" "---" "---"

for i in $(seq 0 $((JOB_COUNT - 1))); do
  JOB_ID=$(yq -r ".jobs[$i].id" "$JOBS_PATH")
  SCHEDULE=$(yq -r ".jobs[$i].schedule" "$JOBS_PATH")
  ENABLED=$(yq -r ".jobs[$i].enabled" "$JOBS_PATH")
  LAST_RUN=$(yq -r ".jobs[$i].last_run // \"-\"" "$JOBS_PATH")
  LAST_STATUS=$(yq -r ".jobs[$i].last_task_status // \"-\"" "$JOBS_PATH")
  ACTIVE=$(yq -r ".jobs[$i].active_task_id // \"-\"" "$JOBS_PATH")

  if [ "$LAST_RUN" = "null" ]; then LAST_RUN="-"; fi
  if [ "$LAST_STATUS" = "null" ]; then LAST_STATUS="-"; fi
  if [ "$ACTIVE" = "null" ]; then ACTIVE="-"; fi

  printf '%-20s %-18s %-8s %-8s %-24s %s\n' "$JOB_ID" "$SCHEDULE" "$ENABLED" "$LAST_STATUS" "$LAST_RUN" "$ACTIVE"
done
