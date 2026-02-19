#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Parse flags
PROJECT_SLUG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_SLUG="$2"; shift 2 ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done

TITLE="${POSITIONAL[0]:-}"
BODY="${POSITIONAL[1]:-}"
LABELS="${POSITIONAL[2]:-}"

if [ -z "$TITLE" ]; then
  echo "usage: add_task.sh [-p owner/repo] \"title\" [\"body\"] [\"label1,label2\"]" >&2
  exit 1
fi

# Resolve PROJECT_DIR from --project flag
if [ -n "$PROJECT_SLUG" ]; then
  BARE_DIR="${ORCH_HOME}/projects/${PROJECT_SLUG}.git"
  if [ -d "$BARE_DIR" ]; then
    PROJECT_DIR="$BARE_DIR"
  else
    echo "Project not found: $PROJECT_SLUG" >&2
    echo "Expected bare repo at: $BARE_DIR" >&2
    echo "Add it with: orchestrator project add $PROJECT_SLUG" >&2
    exit 1
  fi
else
  PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

  # If cwd has no .orchestrator.yml and isn't a known project, check for managed projects
  if [ ! -f "$PROJECT_DIR/.orchestrator.yml" ] && [ -t 0 ]; then
    PROJECTS_DIR="${ORCH_HOME}/projects"
    if [ -d "$PROJECTS_DIR" ]; then
      MANAGED=()
      MANAGED_DIRS=()
      while IFS= read -r bare; do
        [ -n "$bare" ] || continue
        slug=$(git -C "$bare" config remote.origin.url 2>/dev/null \
          | sed -E 's#^https?://github\.com/##; s#^git@github\.com:##; s#\.git$##' || true)
        [ -n "$slug" ] || slug=$(basename "$(dirname "$bare")")/$(basename "$bare" .git)
        MANAGED+=("$slug")
        MANAGED_DIRS+=("$bare")
      done < <(find "$PROJECTS_DIR" -name "*.git" -type d -mindepth 2 -maxdepth 2 2>/dev/null)

      if [ ${#MANAGED[@]} -gt 0 ]; then
        echo "No .orchestrator.yml in current directory."
        echo ""
        echo "Available projects:"
        for i in "${!MANAGED[@]}"; do
          echo "  [$((i + 1))] ${MANAGED[$i]}"
        done
        echo ""
        read -r -p "Select project [1-${#MANAGED[@]}]: " selection
        if [ -n "$selection" ] && [[ "$selection" =~ ^[0-9]+$ ]]; then
          idx=$((selection - 1))
          if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#MANAGED_DIRS[@]} ]; then
            PROJECT_DIR="${MANAGED_DIRS[$idx]}"
          fi
        fi
      fi
    fi
  fi
fi

NOW=$(now_iso)
export NOW PROJECT_DIR

NEXT_ID=$(db_create_task "$TITLE" "$BODY" "${PROJECT_DIR:-}" "$LABELS" "" "")

echo "Added task $NEXT_ID: $TITLE"
