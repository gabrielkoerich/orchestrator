#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required but not found in PATH." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "create-pr.sh must be run inside a git repository." >&2
  exit 1
fi

BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
  echo "Could not determine current branch." >&2
  exit 1
fi

TITLE_FILE=".orchestrator/pr-title.txt"
BODY_FILE=".orchestrator/pr-body.md"

if [ ! -f "$TITLE_FILE" ] || [ ! -f "$BODY_FILE" ]; then
  echo "Missing $TITLE_FILE or $BODY_FILE. Run: scripts/make-pr-body.sh $BASE_BRANCH" >&2
  exit 1
fi

EXISTING=$(gh pr list --head "$BRANCH" --json number,url -q '.[0].url' 2>/dev/null || true)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
  echo "$EXISTING"
  exit 0
fi

TITLE=$(cat "$TITLE_FILE")

gh pr create \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --title "$TITLE" \
  --body-file "$BODY_FILE"

