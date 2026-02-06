#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

"$(dirname "$0")/status.sh"

group() {
  local status="$1"
  printf '\n[%s]\n' "$status"
  yq -r ".tasks | map(select(.status == \"$status\")) | if length == 0 then \"(none)\" else .[] | [(.id|tostring), (.agent // \"-\"), .title] | @tsv end" "$TASKS_PATH" | column -t -s $'\t'
}

group "new"
group "routed"
group "in_progress"
group "blocked"
group "needs_review"
group "done"
