#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
FILTER=$(dir_filter)

ID=$(yq -r "${FILTER} | select(.status == \"new\") | .id" "$TASKS_PATH" | head -n1)
if [ -n "$ID" ]; then
  "$(dirname "$0")/route_task.sh" "$ID" >/dev/null
  "$(dirname "$0")/run_task.sh" "$ID"
  exit 0
fi

# Fallback to any runnable task
"$(dirname "$0")/run_task.sh"
