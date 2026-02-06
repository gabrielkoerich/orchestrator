#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

yq -r '.tasks | if length == 0 then "No tasks." else .[] | [.id, .status, (.agent // "-"), (.parent_id // "-"), .title] | @tsv end' "$TASKS_PATH"
