#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

COUNT=$(task_count)
if [ "$COUNT" -eq 0 ]; then
  echo "No tasks."
  exit 0
fi

task_tsv "[${YQ_TASK_COLS}] | @tsv" \
  | table_with_header "$TASK_HEADER"
