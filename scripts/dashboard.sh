#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"
require_yq
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

FILTER=$(dir_filter)

TOTAL=$(yq -r "[${FILTER}] | length" "$TASKS_PATH")

# Show status summary
count_status() {
  yq -r "[${FILTER} | select(.status == \"$1\")] | length" "$TASKS_PATH"
}

NEW=$(count_status "new")
ROUTED=$(count_status "routed")
INPROG=$(count_status "in_progress")
BLOCKED=$(count_status "blocked")
DONE=$(count_status "done")
NEEDS_REVIEW=$(count_status "needs_review")
TOTAL=$(yq -r "[${FILTER}] | length" "$TASKS_PATH")

if [ "$TOTAL" -eq 0 ]; then
  echo "No tasks."
else
  printf 'Tasks: %s total — %s new, %s routed, %s in_progress, %s blocked, %s done, %s needs_review\n' \
    "$TOTAL" "$NEW" "$ROUTED" "$INPROG" "$BLOCKED" "$DONE" "$NEEDS_REVIEW"

  # Show active tasks (non-done)
  ACTIVE=$(yq -r "[${FILTER} | select(.status != \"done\")] | length" "$TASKS_PATH")
  if [ "$ACTIVE" -gt 0 ]; then
    section "Active tasks:"
    yq -r "[${FILTER} | select(.status != \"done\")] | sort_by(.status) | .[] | [${YQ_TASK_COLS}] | @tsv" "$TASKS_PATH" \
      | table_with_header "$TASK_HEADER"
  fi
fi

# Show active projects
section "Projects:"
PROJECTS=$(yq -r '[.tasks[].dir // ""] | unique | map(select(length > 0)) | .[]' "$TASKS_PATH" 2>/dev/null || true)
if [ -z "$PROJECTS" ]; then
  echo "  (none)"
else
  while IFS= read -r dir; do
    count=$(yq -r "[.tasks[] | select(.dir == \"$dir\" and .status != \"done\")] | length" "$TASKS_PATH")
    printf '  %s (%s active)\n' "$dir" "$count"
  done <<< "$PROJECTS"
fi

# Show active worktrees
section "Worktrees:"
WORKTREE_BASE="${HOME}/.worktrees"
if [ -d "$WORKTREE_BASE" ]; then
  WORKTREES=$(find "$WORKTREE_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null || true)
  if [ -z "$WORKTREES" ]; then
    echo "  (none)"
  else
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      branch=$(cd "$wt" && git branch --show-current 2>/dev/null || echo "?")
      printf '  %s (%s)\n' "$wt" "$branch"
    done <<< "$WORKTREES"
  fi
else
  echo "  (none)"
fi
