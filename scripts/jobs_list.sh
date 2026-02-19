#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"

JOB_COUNT=$(db_scalar "SELECT COUNT(*) FROM jobs;")
if [ "$JOB_COUNT" -eq 0 ]; then
  echo "No jobs configured. Add one with: orchestrator job add \"0 9 * * *\" \"Title\""
  exit 0
fi

{
  printf 'ID\tTYPE\tSCHEDULE\tENABLED\tSTATUS\tLAST RUN\n'
  db_row "SELECT id,
    COALESCE(type, 'task'),
    schedule,
    CASE WHEN enabled = 1 THEN 'true' ELSE 'false' END,
    COALESCE(last_task_status, '-'),
    COALESCE(last_run, '-')
    FROM jobs ORDER BY id;" | while IFS=$'\x1f' read -r jid jtype jsched jenabled jstatus jrun; do
    [ "$jstatus" = "null" ] && jstatus="-"
    [ "$jrun" = "null" ] && jrun="-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$jid" "$jtype" "$jsched" "$jenabled" "$jstatus" "$jrun"
  done
} | column -t -s $'\t'
