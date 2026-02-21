#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"
ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="${ROOT}/.orchestrator"
TITLE_FILE="${OUT_DIR}/pr-title.txt"
BODY_FILE="${OUT_DIR}/pr-body.md"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"${SCRIPT_DIR}/make-pr-body.sh" "${BASE_BRANCH}" >/dev/null

BRANCH="$(git branch --show-current)"

if gh pr view --head "${BRANCH}" --json url -q .url >/dev/null 2>&1; then
  gh pr view --head "${BRANCH}" --json url,title -q '"PR already exists: \(.url) (\(.title))"'
  exit 0
fi

TITLE="$(cat "${TITLE_FILE}")"

gh pr create \
  --base "${BASE_BRANCH}" \
  --head "${BRANCH}" \
  --title "${TITLE}" \
  --body-file "${BODY_FILE}"
