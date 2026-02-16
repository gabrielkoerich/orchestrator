#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

"$(dirname "$0")/status.sh"

YQ_GROUP_COLS=".id, ${YQ_AGENT}, ${YQ_ISSUE}, .title"
GROUP_HEADER="ID\tAGENT\tISSUE\tTITLE"

group() {
  local status="$1"
  section "[$status]"
  local data
  data=$(task_tsv "[${YQ_GROUP_COLS}] | @tsv" "select(.status == \"$status\")")
  if [ -z "$data" ]; then
    echo "(none)"
  else
    printf '%s\n' "$data" | table_with_header "$GROUP_HEADER"
  fi
}

group "new"
group "routed"
group "in_progress"
group "blocked"
group "needs_review"
group "done"
