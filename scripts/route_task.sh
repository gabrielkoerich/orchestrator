#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    echo "No new tasks to route" >&2
    exit 1
  fi
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

ROUTED_AGENT=$(printf '%s' "$RESPONSE" | yq -r '.executor')
REASON=$(printf '%s' "$RESPONSE" | yq -r '.reason')
PROFILE_JSON=$(printf '%s' "$RESPONSE" | yq -o=json -I=0 '.profile // {}')
NOW=$(now_iso)

export ROUTED_AGENT REASON PROFILE_JSON NOW

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .agent) = env(ROUTED_AGENT) | \
   (.tasks[] | select(.id == $TASK_ID) | .status) = \"routed\" | \
   (.tasks[] | select(.id == $TASK_ID) | .route_reason) = env(REASON) | \
   (.tasks[] | select(.id == $TASK_ID) | .agent_profile) = (env(PROFILE_JSON) | fromjson) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

echo "$ROUTED_AGENT"
