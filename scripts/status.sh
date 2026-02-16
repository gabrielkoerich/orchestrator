#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

# Parse flags
IS_GLOBAL=false
IS_JSON=false
for arg in "$@"; do
  case "$arg" in
    --global|-g) IS_GLOBAL=true ;;
    --json)      IS_JSON=true ;;
  esac
done

# Global mode: show all tasks across projects
if [ "$IS_GLOBAL" = true ]; then
  FILTER=".tasks[]"
else
  FILTER=$(dir_filter)
fi

if [ "$IS_JSON" = true ]; then
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

count_status() {
  yq -r "[${FILTER} | select(.status == \"$1\")] | length" "$TASKS_PATH"
}

NEW=$(count_status "new")
ROUTED=$(count_status "routed")
INPROG=$(count_status "in_progress")
BLOCKED=$(count_status "blocked")
DONE=$(count_status "done")
NEEDS_REVIEW=$(count_status "needs_review")
TOTAL=$((NEW + ROUTED + INPROG + BLOCKED + DONE + NEEDS_REVIEW))

{
  printf 'STATUS\tQTY\n'
  printf 'new\t%s\n' "$NEW"
  printf 'routed\t%s\n' "$ROUTED"
  printf 'in_progress\t%s\n' "$INPROG"
  printf 'blocked\t%s\n' "$BLOCKED"
  printf 'done\t%s\n' "$DONE"
  printf 'needs_review\t%s\n' "$NEEDS_REVIEW"
  printf '────────\t───\n'
  printf 'total\t%s\n' "$TOTAL"
} | column -t -s $'\t'

section "Recent tasks:"
if [ "$IS_GLOBAL" = true ]; then
  yq -r "[${FILTER}] | sort_by(.updated_at) | reverse | .[0:10] | .[] | [${YQ_TASK_COLS_GLOBAL}] | @tsv" "$TASKS_PATH" \
    | table_with_header "$TASK_HEADER_GLOBAL"
else
  yq -r "[${FILTER}] | sort_by(.updated_at) | reverse | .[0:10] | .[] | [${YQ_TASK_COLS}] | @tsv" "$TASKS_PATH" \
    | table_with_header "$TASK_HEADER"
fi
