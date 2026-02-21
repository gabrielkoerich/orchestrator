#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${1:-main}"
BRANCH="$(git branch --show-current)"

if [ -z "${BRANCH}" ]; then
  echo "error: not on a git branch" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="${ROOT}/.orchestrator"
TITLE_FILE="${OUT_DIR}/pr-title.txt"
BODY_FILE="${OUT_DIR}/pr-body.md"

mkdir -p "${OUT_DIR}"

ISSUE_NUM=""
if [[ "${BRANCH}" =~ gh-task-([0-9]+)- ]]; then
  ISSUE_NUM="${BASH_REMATCH[1]}"
fi

if [ -n "${PR_TITLE:-}" ]; then
  TITLE="${PR_TITLE}"
elif [ -n "${ISSUE_NUM}" ]; then
  TITLE="chore: close duplicate improvement issues (#${ISSUE_NUM})"
else
  TITLE="chore: close duplicate improvement issues"
fi

{
  echo "## Summary"
  echo ""
  git log --oneline --reverse "${BASE_BRANCH}..HEAD" | sed 's/^/- /'
  echo ""
  echo "## Changes"
  echo ""
  git diff --stat "${BASE_BRANCH}..HEAD" | sed 's/^/- /'
  if [ -n "${ISSUE_NUM}" ]; then
    echo ""
    echo "Closes #${ISSUE_NUM}"
  fi
} >"${BODY_FILE}"

printf '%s\n' "${TITLE}" >"${TITLE_FILE}"

echo "Wrote:"
echo "  ${TITLE_FILE}"
echo "  ${BODY_FILE}"
