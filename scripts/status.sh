#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
FILTER=$(dir_filter)

if [ "${1:-}" = "--json" ]; then
  yq -o=json -I=2 "{
    total: ([${FILTER}] | length),
    counts: {
      new: ([${FILTER} | select(.status == \"new\")] | length),
      routed: ([${FILTER} | select(.status == \"routed\")] | length),
      in_progress: ([${FILTER} | select(.status == \"in_progress\")] | length),
      blocked: ([${FILTER} | select(.status == \"blocked\")] | length),
      done: ([${FILTER} | select(.status == \"done\")] | length),
      needs_review: ([${FILTER} | select(.status == \"needs_review\")] | length)
    },
    recent: ([${FILTER}] | sort_by(.updated_at) | reverse | .[0:10])
  }" "$TASKS_PATH"
  exit 0
fi

TOTAL=$(yq -r "[${FILTER}] | length" "$TASKS_PATH")
NEW=$(yq -r "[${FILTER} | select(.status == \"new\")] | length" "$TASKS_PATH")
ROUTED=$(yq -r "[${FILTER} | select(.status == \"routed\")] | length" "$TASKS_PATH")
INPROG=$(yq -r "[${FILTER} | select(.status == \"in_progress\")] | length" "$TASKS_PATH")
BLOCKED=$(yq -r "[${FILTER} | select(.status == \"blocked\")] | length" "$TASKS_PATH")
DONE=$(yq -r "[${FILTER} | select(.status == \"done\")] | length" "$TASKS_PATH")
NEEDS_REVIEW=$(yq -r "[${FILTER} | select(.status == \"needs_review\")] | length" "$TASKS_PATH")

printf 'Total: %s\n' "$TOTAL"
printf 'new: %s\n' "$NEW"
printf 'routed: %s\n' "$ROUTED"
printf 'in_progress: %s\n' "$INPROG"
printf 'blocked: %s\n' "$BLOCKED"
printf 'done: %s\n' "$DONE"
printf 'needs_review: %s\n' "$NEEDS_REVIEW"

printf '\nRecent tasks:\n'
yq -r "[${FILTER}] | sort_by(.updated_at) | reverse | .[0:10] | .[] | [.id, .status, (.agent // \"-\"), .title] | @tsv" "$TASKS_PATH" | column -t -s $'\t'
