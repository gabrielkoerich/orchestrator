#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

TITLE=${1:-}
BODY=${2:-}
LABELS=${3:-}
if [ -z "$TITLE" ]; then
  echo "usage: add_task.sh \"title\" [\"body\"] [\"label1,label2\"]" >&2
  exit 1
fi

BODY=${BODY:-}
LABELS=${LABELS:-}
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
NOW=$(now_iso)
export NOW PROJECT_DIR

# Compute ID inside lock to prevent race conditions
acquire_lock
NEXT_ID=$(yq -r '((.tasks | map(.id) | max) // 0) + 1' "$TASKS_PATH")
create_task_entry "$NEXT_ID" "$TITLE" "$BODY" "$LABELS"
release_lock

echo "Added task $NEXT_ID: $TITLE"
