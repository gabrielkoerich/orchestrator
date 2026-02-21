#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

BRANCH=$(git branch --show-current)

TITLE_FILE=".orchestrator/pr-title.txt"
BODY_FILE=".orchestrator/pr-body.md"

if [ ! -f "$TITLE_FILE" ] || [ ! -f "$BODY_FILE" ]; then
  "$(dirname "$0")/make-pr-body.sh" "$BASE_BRANCH"
fi

if gh pr view "$BRANCH" --json url --jq '.url' >/dev/null 2>&1; then
  gh pr view "$BRANCH" --json url --jq '.url'
  exit 0
fi

TITLE=$(cat "$TITLE_FILE")
gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE"

