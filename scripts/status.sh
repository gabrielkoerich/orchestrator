#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"

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

# Determine dir filter
if [ "$IS_GLOBAL" = true ]; then
  DIR_WHERE="1=1"
else
  DIR_WHERE=$(db_dir_where)
fi

if [ "$IS_JSON" = true ]; then
  db_status_json "$DIR_WHERE"
  exit 0
fi

TOTAL=$(db_scalar "SELECT COUNT(*) FROM tasks WHERE $DIR_WHERE;")

if [ "$TOTAL" -eq 0 ]; then
  echo "No tasks. Add one with: orchestrator task add \"title\""
  exit 0
fi

_count() {
  db_scalar "SELECT COUNT(*) FROM tasks WHERE $DIR_WHERE AND status = '$1';"
}

NEW=$(_count "new")
ROUTED=$(_count "routed")
INPROG=$(_count "in_progress")
BLOCKED=$(_count "blocked")
DONE=$(_count "done")
NEEDS_REVIEW=$(_count "needs_review")

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
  db_task_display_tsv_global "1=1" "updated_at DESC" "10" \
    | table_with_header "$TASK_HEADER_GLOBAL"
else
  db_task_display_tsv "1=1" "updated_at DESC" "10" \
    | table_with_header "$TASK_HEADER"
fi
