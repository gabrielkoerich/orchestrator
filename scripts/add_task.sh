#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

TITLE=${1:-}
BODY=${2:-}
LABELS=${3:-}
if [ -z "$TITLE" ]; then
  echo "usage: add_task.sh \"title\" [\"body\"] [\"label1,label2\"]" >&2
  exit 1
fi

NEXT_ID=$(yq -r '((.tasks | map(.id) | max) // 0) + 1' "$TASKS_PATH")
NOW=$(now_iso)

BODY=${BODY:-}
LABELS=${LABELS:-}
export NEXT_ID TITLE BODY LABELS NOW

with_lock yq -i \
  '.tasks += [{
    "id": (env(NEXT_ID) | tonumber),
    "title": env(TITLE),
    "body": strenv(BODY),
    "labels": (strenv(LABELS) | split(",") | map(select(length > 0))),
    "status": "new",
    "agent": null,
    "agent_model": null,
    "agent_profile": null,
    "selected_skills": [],
    "parent_id": null,
    "children": [],
    "route_reason": null,
    "route_warning": null,
    "summary": null,
    "accomplished": [],
    "remaining": [],
    "blockers": [],
    "files_changed": [],
    "needs_help": false,
    "attempts": 0,
    "last_error": null,
    "retry_at": null,
    "review_decision": null,
    "review_notes": null,
    "history": [],
    "created_at": env(NOW),
    "updated_at": env(NOW)
  }]' \
  "$TASKS_PATH"

echo "Added task $NEXT_ID"
