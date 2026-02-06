#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

TITLE=${1:-}
BODY=${2:-}
LABELS=${3:-}
if [ -z "$TITLE" ]; then
  echo "usage: add_task.sh \"title\" \"body\" \"label1,label2\"" >&2
  exit 1
fi

NEXT_ID=$(yq -r '.tasks | map(.id) | max // 0 | . + 1' "$TASKS_PATH")
NOW=$(now_iso)

LABELS_JSON="[]"
if [ -n "$LABELS" ]; then
  IFS=',' read -r -a arr <<< "$LABELS"
  LABELS_JSON=$(printf '%s\n' "${arr[@]}" | yq -o=json -I=0 '[.]')
fi

export NEXT_ID TITLE BODY LABELS_JSON NOW

yq -i \
  '.tasks += [{
    "id": (env(NEXT_ID) | tonumber),
    "title": env(TITLE),
    "body": env(BODY),
    "labels": (env(LABELS_JSON) | fromjson),
    "status": "new",
    "agent": null,
    "parent_id": null,
    "children": [],
    "route_reason": null,
    "summary": null,
    "files_changed": [],
    "needs_help": false,
    "created_at": env(NOW),
    "updated_at": env(NOW)
  }]' \
  "$TASKS_PATH"

echo "Added task $NEXT_ID"
