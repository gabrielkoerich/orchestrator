#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_config_file
load_project_config
if [ "${DEBUG_GH:-0}" = "1" ]; then
  set -x
fi

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh
init_tasks_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

REPO=${GITHUB_REPO:-$(config_get '.gh.repo // ""')}
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.git" ]; then
    REPO=$(cd "$PROJECT_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi
  if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  fi
fi

SYNC_LABEL=${GITHUB_SYNC_LABEL:-$(config_get '.gh.sync_label // ""')}
GH_BACKOFF_MODE=${GITHUB_BACKOFF_MODE:-$(config_get '.gh.backoff.mode // "wait"')}
GH_BACKOFF_BASE_SECONDS=${GITHUB_BACKOFF_BASE_SECONDS:-$(config_get '.gh.backoff.base_seconds // 30')}
GH_BACKOFF_MAX_SECONDS=${GITHUB_BACKOFF_MAX_SECONDS:-$(config_get '.gh.backoff.max_seconds // 900')}
export GH_BACKOFF_MODE GH_BACKOFF_BASE_SECONDS GH_BACKOFF_MAX_SECONDS

echo "[gh_pull] repo=$REPO"
ISSUES_JSON=$(gh_api -X GET "repos/$REPO/issues" --paginate -f state=all -f per_page=100)
FILTERED=$(printf '%s' "$ISSUES_JSON" | yq -o=json -I=0 'map(select(.pull_request == null))')
if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
  FILTERED=$(printf '%s' "$FILTERED" | yq -o=json -I=0 "map(select(.labels | map(.name) | index(\"$SYNC_LABEL\") != null))")
fi

acquire_lock

trap 'release_lock' EXIT INT TERM

COUNT=$(printf '%s' "$FILTERED" | yq -r 'length')
if [ "$COUNT" -le 0 ]; then
  release_lock
  exit 0
fi

export LABELS_CSV=""
for i in $(seq 0 $((COUNT - 1))); do
  NUM=$(printf '%s' "$FILTERED" | yq -r ".[$i].number")
  TITLE=$(printf '%s' "$FILTERED" | yq -r ".[$i].title")
  BODY=$(printf '%s' "$FILTERED" | yq -r ".[$i].body // \"\"")
  LABELS_CSV=$(printf '%s' "$FILTERED" | yq -r ".[$i].labels | map(.name) | join(\",\")")
  LABELS_CSV=${LABELS_CSV:-""}
  export LABELS_CSV
  STATE=$(printf '%s' "$FILTERED" | yq -r ".[$i].state")
  URL=$(printf '%s' "$FILTERED" | yq -r ".[$i].html_url")
  UPDATED=$(printf '%s' "$FILTERED" | yq -r ".[$i].updated_at")

  EXISTS=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .id" "$TASKS_PATH")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "null" ]; then
    export TITLE BODY LABELS_CSV STATE URL UPDATED
    yq -i \
      "(.tasks[] | select(.gh_issue_number == $NUM) | .title) = env(TITLE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .body) = env(BODY) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .labels) = (strenv(LABELS_CSV) | split(\",\") | map(select(length > 0))) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_state) = env(STATE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_url) = env(URL) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_updated_at) = env(UPDATED)" \
      "$TASKS_PATH"

    if [ "$STATE" = "closed" ]; then
      NOW=$(now_iso)
      export NOW
      yq -i \
        "(.tasks[] | select(.gh_issue_number == $NUM) | .status) = \"done\" | \
         (.tasks[] | select(.gh_issue_number == $NUM) | .updated_at) = env(NOW)" \
        "$TASKS_PATH"
    fi
  else
    NEXT_ID=$(yq -r '((.tasks | map(.id) | max) // 0) + 1' "$TASKS_PATH")
    NOW=$(now_iso)
    STATUS="new"
    if [ "$STATE" = "closed" ]; then
      STATUS="done"
    fi
    export NEXT_ID TITLE BODY LABELS_CSV STATUS NOW STATE URL UPDATED NUM

    yq -i \
      '.tasks += [{
        "id": (env(NEXT_ID) | tonumber),
        "title": env(TITLE),
        "body": env(BODY),
        "labels": (strenv(LABELS_CSV) | split(",") | map(select(length > 0))),
        "status": env(STATUS),
        "agent": null,
        "agent_profile": null,
        "parent_id": null,
        "children": [],
        "route_reason": null,
        "route_warning": null,
        "summary": null,
        "files_changed": [],
        "needs_help": false,
        "attempts": 0,
        "last_error": null,
        "retry_at": null,
        "review_decision": null,
        "review_notes": null,
        "history": [],
        "created_at": env(NOW),
        "updated_at": env(NOW),
        "gh_issue_number": (env(NUM) | tonumber),
        "gh_state": env(STATE),
        "gh_url": env(URL),
        "gh_updated_at": env(UPDATED),
        "dir": env(PROJECT_DIR),
        "gh_synced_at": null
      }]' \
      "$TASKS_PATH"
  fi

done

release_lock
