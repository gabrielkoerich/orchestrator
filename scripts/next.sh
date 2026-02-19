#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

ID=$(db_scalar "SELECT id FROM tasks WHERE status = 'new'
  AND (dir = '$(sql_escape "$PROJECT_DIR")' OR dir IS NULL OR dir = '')
  ORDER BY id LIMIT 1;" 2>/dev/null || true)
if [ -n "$ID" ]; then
  "$(dirname "$0")/route_task.sh" "$ID" >/dev/null
  "$(dirname "$0")/run_task.sh" "$ID"
  exit 0
fi

# Fallback to any runnable task
"$(dirname "$0")/run_task.sh"
