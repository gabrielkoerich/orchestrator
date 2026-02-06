#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

COUNT=$(yq -r '.tasks | length' "$TASKS_PATH")
if [ "$COUNT" -eq 0 ]; then
  echo "No tasks."
  exit 0
fi

yq -r '.tasks[] | [.id, .status, (.agent // "-"), (.parent_id // "-"), .title] | @tsv' "$TASKS_PATH"
