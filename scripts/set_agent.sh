#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

TASK_ID=${1:-}
AGENT=${2:-}
if [ -z "$TASK_ID" ] || [ -z "$AGENT" ]; then
  echo "usage: set_agent.sh TASK_ID codex|claude" >&2
  exit 1
fi

NOW=$(now_iso)
export AGENT NOW

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .agent) = strenv(AGENT) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

append_history "$TASK_ID" "routed" "agent manually set to $AGENT"

