#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "make-pr-body.sh must be run inside a git repository." >&2
  exit 1
fi

BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
  echo "Could not determine current branch." >&2
  exit 1
fi

mkdir -p .orchestrator

TITLE_FILE=".orchestrator/pr-title.txt"
BODY_FILE=".orchestrator/pr-body.md"

ISSUE_NUM=""
if [[ "$BRANCH" =~ gh-task-([0-9]+)- ]]; then
  ISSUE_NUM="${BASH_REMATCH[1]}"
fi

COMMITS=$(git log --no-merges --pretty=format:'- %s (%h)' "${BASE_BRANCH}..HEAD" 2>/dev/null || true)
FILES=$(git diff --name-only "${BASE_BRANCH}..HEAD" 2>/dev/null || true)

TITLE=$(git log --no-merges --pretty=format:'%s' -1 HEAD 2>/dev/null || echo "$BRANCH")
printf '%s\n' "$TITLE" > "$TITLE_FILE"

{
  echo "## Summary"
  echo
  echo "_Auto-generated from \`${BASE_BRANCH}..${BRANCH}\`._"
  echo

  if [ -n "$COMMITS" ]; then
    echo "## Commits"
    echo
    echo "$COMMITS"
    echo
  fi

  if [ -n "$FILES" ]; then
    echo "## Files Changed"
    echo
    printf '%s\n' "$FILES" | sed 's/^/- `/' | sed 's/$/`/'
    echo
  fi

  if [ -n "$ISSUE_NUM" ]; then
    echo "Closes #${ISSUE_NUM}"
    echo
  fi
} > "$BODY_FILE"

echo "$TITLE_FILE"
echo "$BODY_FILE"

