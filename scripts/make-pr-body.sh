#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

BRANCH=$(git branch --show-current)
TITLE=$(git log -1 --pretty=%s)

ISSUE_NUMBER=""
if [[ "$BRANCH" =~ ^gh-task-([0-9]+)- ]]; then
  ISSUE_NUMBER="${BASH_REMATCH[1]}"
fi

mkdir -p .orchestrator
TITLE_FILE=".orchestrator/pr-title.txt"
BODY_FILE=".orchestrator/pr-body.md"

COMMITS=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null || true)
FILES=$(git diff --name-only "${BASE_BRANCH}..HEAD" 2>/dev/null || true)

printf '%s\n' "$TITLE" > "$TITLE_FILE"

{
  printf '## Summary\n\n'
  printf '%s\n' "- Implements fail-fast environment validation before agent execution."
  printf '\n## Changes\n\n'
  if [ -n "$COMMITS" ]; then
    printf '%s\n' "$COMMITS" | sed 's/^/- /'
  else
    printf '%s\n' "- (no commits detected vs ${BASE_BRANCH})"
  fi
  printf '\n## Files Touched\n\n'
  if [ -n "$FILES" ]; then
    printf '%s\n' "$FILES" | sed 's/^/- `/' | sed 's/$/`/'
  else
    printf '%s\n' "- (no file changes detected vs ${BASE_BRANCH})"
  fi
  if [ -n "$ISSUE_NUMBER" ]; then
    printf '\n## Link\n\n'
    printf '%s\n' "Closes #${ISSUE_NUMBER}"
  fi
} > "$BODY_FILE"

echo "Wrote $TITLE_FILE and $BODY_FILE"

