#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    TASK_ID=$(yq -r '.tasks[] | select(.status == "routed") | .id' "$TASKS_PATH" | head -n1)
  fi
  if [ -z "$TASK_ID" ]; then
    echo "No runnable tasks found" >&2
    exit 1
  fi
fi

# Per-task lock to avoid double-run across multiple watchers
TASK_LOCK="${LOCK_PATH}.task.${TASK_ID}"
if ! mkdir "$TASK_LOCK" 2>/dev/null; then
  echo "Task $TASK_ID already running" >&2
  exit 0
fi
trap 'rmdir "$TASK_LOCK" 2>/dev/null || true' EXIT

TASK_TITLE=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .title" "$TASKS_PATH")
TASK_BODY=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .body" "$TASKS_PATH")
TASK_LABELS=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .labels | join(\",\")" "$TASKS_PATH")
TASK_AGENT=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .agent" "$TASKS_PATH")
AGENT_PROFILE_JSON=$(yq -o=json -I=0 ".tasks[] | select(.id == $TASK_ID) | .agent_profile // {}" "$TASKS_PATH")

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  echo "Task $TASK_ID not found" >&2
  exit 1
fi

if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
  TASK_AGENT=$("$(dirname "$0")/route_task.sh" "$TASK_ID")
  AGENT_PROFILE_JSON=$(yq -o=json -I=0 ".tasks[] | select(.id == $TASK_ID) | .agent_profile // {}" "$TASKS_PATH")
fi

NOW=$(now_iso)
export NOW

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = \"in_progress\" | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

PROMPT=$(render_template "prompts/agent.md" "$TASK_ID" "$TASK_TITLE" "$TASK_LABELS" "$TASK_BODY" "$AGENT_PROFILE_JSON")

case "$TASK_AGENT" in
  codex)
    RESPONSE=$(codex --print "$PROMPT")
    ;;
  claude)
    RESPONSE=$(claude --print "$PROMPT")
    ;;
  *)
    echo "Unknown agent: $TASK_AGENT" >&2
    exit 1
    ;;
 esac

AGENT_STATUS=$(printf '%s' "$RESPONSE" | yq -r '.status')
SUMMARY=$(printf '%s' "$RESPONSE" | yq -r '.summary // ""')
FILES_CHANGED_JSON=$(printf '%s' "$RESPONSE" | yq -o=json -I=0 '.files_changed // []')
NEEDS_HELP=$(printf '%s' "$RESPONSE" | yq -r '.needs_help // false')
DELEGATIONS_JSON=$(printf '%s' "$RESPONSE" | yq -o=json -I=0 '.delegations // []')

if [ -z "$AGENT_STATUS" ] || [ "$AGENT_STATUS" = "null" ]; then
  echo "Agent response missing status" >&2
  exit 1
fi

NOW=$(now_iso)
export AGENT_STATUS SUMMARY FILES_CHANGED_JSON NEEDS_HELP NOW

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = env(AGENT_STATUS) | \
   (.tasks[] | select(.id == $TASK_ID) | .summary) = env(SUMMARY) | \
   (.tasks[] | select(.id == $TASK_ID) | .files_changed) = (env(FILES_CHANGED_JSON) | fromjson) | \
   (.tasks[] | select(.id == $TASK_ID) | .needs_help) = (env(NEEDS_HELP) == \"true\") | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

DELEG_COUNT=$(printf '%s' "$DELEGATIONS_JSON" | yq -r 'length')

if [ "$DELEG_COUNT" -gt 0 ]; then
  acquire_lock

  MAX_ID=$(yq -r '.tasks | map(.id) | max // 0' "$TASKS_PATH")
  CHILD_IDS=()
  for i in $(seq 0 $((DELEG_COUNT - 1))); do
    TITLE=$(printf '%s' "$DELEGATIONS_JSON" | yq -r ".[$i].title // \"\"")
    BODY=$(printf '%s' "$DELEGATIONS_JSON" | yq -r ".[$i].body // \"\"")
    LABELS_JSON=$(printf '%s' "$DELEGATIONS_JSON" | yq -o=json -I=0 ".[$i].labels // []")
    SUGGESTED_AGENT=$(printf '%s' "$DELEGATIONS_JSON" | yq -r ".[$i].suggested_agent // \"\"")

    MAX_ID=$((MAX_ID + 1))
    NOW=$(now_iso)
    export MAX_ID TITLE BODY LABELS_JSON SUGGESTED_AGENT NOW

    yq -i \
      '.tasks += [{
        "id": (env(MAX_ID) | tonumber),
        "title": env(TITLE),
        "body": env(BODY),
        "labels": (env(LABELS_JSON) | fromjson),
        "status": "new",
        "agent": (env(SUGGESTED_AGENT) | select(length > 0) // null),
        "parent_id": $TASK_ID,
        "children": [],
        "route_reason": null,
        "summary": null,
        "files_changed": [],
        "needs_help": false,
        "agent_profile": null,
        "created_at": env(NOW),
        "updated_at": env(NOW)
      }]' \
      "$TASKS_PATH"

    yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .children) += [$MAX_ID]" \
      "$TASKS_PATH"

    CHILD_IDS+=("$MAX_ID")
  done

  NOW=$(now_iso)
  export NOW
  yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"blocked\" | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"

  release_lock

  printf 'Spawned children: %s\n' "${CHILD_IDS[*]}"
fi
