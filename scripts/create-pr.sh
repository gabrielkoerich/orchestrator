#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ ! -f .orchestrator/pr-title.txt ] || [ ! -f .orchestrator/pr-body.md ]; then
  scripts/make-pr-body.sh "$BASE_BRANCH" >/dev/null
fi

if [ ! -f .orchestrator/pr-title.txt ]; then
  echo "Error: .orchestrator/pr-title.txt not found" >&2
  exit 1
fi

BRANCH=$(git branch --show-current)
TITLE=$(cat .orchestrator/pr-title.txt)

if [ -z "$TITLE" ]; then
  echo "Error: PR title is empty. Ensure you have commits on the branch." >&2
  exit 1
fi

if gh pr view "$BRANCH" --json url --jq .url >/dev/null 2>&1; then
  gh pr view "$BRANCH" --json url --jq .url
  exit 0
fi

gh pr create \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --title "$TITLE" \
  --body-file .orchestrator/pr-body.md
