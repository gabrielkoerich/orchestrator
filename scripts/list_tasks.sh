#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
FILTER=$(dir_filter)

COUNT=$(yq -r "[${FILTER}] | length" "$TASKS_PATH")
if [ "$COUNT" -eq 0 ]; then
  echo "No tasks."
  exit 0
fi

yq -r "${FILTER} | [.id, .status, (.agent // \"-\"), (.parent_id // \"-\"), .title] | @tsv" "$TASKS_PATH"
