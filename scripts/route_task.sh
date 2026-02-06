#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  echo "usage: route_task.sh TASK_ID" >&2
  exit 1
fi

TASK_TITLE=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .title" "$TASKS_PATH")
TASK_BODY=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .body" "$TASKS_PATH")
TASK_LABELS=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .labels | join(\",\")" "$TASKS_PATH")
ROUTER_AGENT=$(yq -r '.router.agent' "$TASKS_PATH")

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  echo "Task $TASK_ID not found" >&2
  exit 1
fi

PROMPT=$(render_template "prompts/route.md" "$TASK_ID" "$TASK_TITLE" "$TASK_LABELS" "$TASK_BODY")

case "$ROUTER_AGENT" in
  codex)
    RESPONSE=$(codex --print "$PROMPT")
    ;;
  claude)
    RESPONSE=$(claude --print "$PROMPT")
    ;;
  *)
    echo "Unknown router agent: $ROUTER_AGENT" >&2
    exit 1
    ;;
 esac

ROUTED_AGENT=$(printf '%s' "$RESPONSE" | yq -r '.agent')
REASON=$(printf '%s' "$RESPONSE" | yq -r '.reason')
NOW=$(now_iso)

export ROUTED_AGENT REASON NOW

yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .agent) = env(ROUTED_AGENT) | \
   (.tasks[] | select(.id == $TASK_ID) | .status) = \"routed\" | \
   (.tasks[] | select(.id == $TASK_ID) | .route_reason) = env(REASON) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

echo "$ROUTED_AGENT"
