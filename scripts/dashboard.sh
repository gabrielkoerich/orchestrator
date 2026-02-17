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
IN_REVIEW=$(count_status "in_review")
DONE=$(count_status "done")
NEEDS_REVIEW=$(count_status "needs_review")
TOTAL=$(yq -r "[${FILTER}] | length" "$TASKS_PATH")

if [ "$TOTAL" -eq 0 ]; then
  echo "No tasks."
else
  printf 'Tasks: %s total — %s new, %s routed, %s in_progress, %s in_review, %s blocked, %s done, %s needs_review\n' \
    "$TOTAL" "$NEW" "$ROUTED" "$INPROG" "$IN_REVIEW" "$BLOCKED" "$DONE" "$NEEDS_REVIEW"

  # Show active tasks (non-done)
  ACTIVE=$(yq -r "[${FILTER} | select(.status != \"done\")] | length" "$TASKS_PATH")
  if [ "$ACTIVE" -gt 0 ]; then
    section "Active tasks:"
    yq -r "[${FILTER} | select(.status != \"done\")] | sort_by(.status) | .[] | [${YQ_TASK_COLS}] | @tsv" "$TASKS_PATH" \
      | table_with_header "$TASK_HEADER"
  fi
fi

# Token usage and cost summary
# Extract per-task data: input_tokens, output_tokens, duration, model — compute totals with awk
USAGE_TSV=$(yq -r "[${FILTER} | select(.input_tokens != null and .input_tokens > 0)] | .[] | [.input_tokens, .output_tokens // 0, .duration // 0, .agent_model // \"sonnet\"] | @tsv" "$TASKS_PATH" 2>/dev/null || true)
if [ -n "$USAGE_TSV" ]; then
  section "Usage:"
  # Pricing per 1M tokens (USD) — approximate
  # Claude: haiku=$0.25/$1.25, sonnet=$3/$15, opus=$15/$75
  # Codex: gpt-5.1-mini=$0.30/$1.20, gpt-5.2=$2.50/$10, gpt-5.3=$15/$60
  USAGE_SUMMARY=$(printf '%s\n' "$USAGE_TSV" | awk -F'\t' '
    BEGIN { ti=0; to=0; dur=0; cost=0 }
    {
      ti += $1; to += $2; dur += $3
      m = $4
      if (m == "haiku" || m == "gpt-5.1-codex-mini")
        cost += ($1 * 0.25 + $2 * 1.25) / 1000000
      else if (m == "opus" || m == "gpt-5.3-codex")
        cost += ($1 * 15 + $2 * 75) / 1000000
      else
        cost += ($1 * 3 + $2 * 15) / 1000000
    }
    END { printf "%d\t%d\t%d\t%.2f", ti, to, dur, cost }
  ')
  TOTAL_INPUT=$(printf '%s' "$USAGE_SUMMARY" | cut -f1)
  TOTAL_OUTPUT=$(printf '%s' "$USAGE_SUMMARY" | cut -f2)
  TOTAL_DURATION=$(printf '%s' "$USAGE_SUMMARY" | cut -f3)
  TOTAL_COST=$(printf '%s' "$USAGE_SUMMARY" | cut -f4)
  printf '  Tokens: %s input / %s output\n' "$TOTAL_INPUT" "$TOTAL_OUTPUT"
  printf '  Duration: %s\n' "$(duration_fmt "$TOTAL_DURATION")"
  printf '  Estimated cost: $%s\n' "$TOTAL_COST"
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
