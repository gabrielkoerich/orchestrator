#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

TOTAL=$(yq -r '.tasks | length' "$TASKS_PATH")
NEW=$(yq -r '[.tasks[] | select(.status == "new")] | length' "$TASKS_PATH")
ROUTED=$(yq -r '[.tasks[] | select(.status == "routed")] | length' "$TASKS_PATH")
INPROG=$(yq -r '[.tasks[] | select(.status == "in_progress")] | length' "$TASKS_PATH")
BLOCKED=$(yq -r '[.tasks[] | select(.status == "blocked")] | length' "$TASKS_PATH")
DONE=$(yq -r '[.tasks[] | select(.status == "done")] | length' "$TASKS_PATH")
NEEDS_REVIEW=$(yq -r '[.tasks[] | select(.status == "needs_review")] | length' "$TASKS_PATH")

printf 'Total: %s\n' "$TOTAL"
printf 'new: %s\n' "$NEW"
printf 'routed: %s\n' "$ROUTED"
printf 'in_progress: %s\n' "$INPROG"
printf 'blocked: %s\n' "$BLOCKED"
printf 'done: %s\n' "$DONE"
printf 'needs_review: %s\n' "$NEEDS_REVIEW"

printf '\nRecent tasks:\n'
yq -r '.tasks | sort_by(.updated_at) | reverse | .[0:10] | .[] | [.id, .status, (.agent // "-"), .title] | @tsv' "$TASKS_PATH" | column -t -s $'\t'
