#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
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

REPO=${GITHUB_REPO:-$(config_get '.gh.repo // ""')}
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.git" ]; then
    REPO=$(cd "$PROJECT_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi
  if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
    log_err "[gh_pull] no repo configured. Run 'orchestrator init' first."
    exit 1
  fi
fi

SYNC_LABEL=${GITHUB_SYNC_LABEL:-$(config_get '.gh.sync_label // ""')}
GH_BACKOFF_MODE=${GITHUB_BACKOFF_MODE:-$(config_get '.gh.backoff.mode // "wait"')}
GH_BACKOFF_BASE_SECONDS=${GITHUB_BACKOFF_BASE_SECONDS:-$(config_get '.gh.backoff.base_seconds // 30')}
GH_BACKOFF_MAX_SECONDS=${GITHUB_BACKOFF_MAX_SECONDS:-$(config_get '.gh.backoff.max_seconds // 900')}
export GH_BACKOFF_MODE GH_BACKOFF_BASE_SECONDS GH_BACKOFF_MAX_SECONDS

log "[gh_pull] repo=$REPO"
ISSUES_JSON=$(gh_api -X GET "repos/$REPO/issues" --paginate -f state=all -f per_page=100)
# gh api --paginate may return one JSON array per page; merge into one
ISSUES_JSON=$(printf '%s' "$ISSUES_JSON" | yq ea -p=json -o=json -I=0 '[.[]]')
FILTERED=$(printf '%s' "$ISSUES_JSON" | yq -o=json -I=0 'map(select(.pull_request == null))')
if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
  FILTERED=$(printf '%s' "$FILTERED" | yq -o=json -I=0 "map(select(.labels | map(.name) | any_c(. == \"$SYNC_LABEL\")))")
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
      "(.tasks[] | select(.gh_issue_number == $NUM) | .title) = strenv(TITLE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .body) = strenv(BODY) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .labels) = (strenv(LABELS_CSV) | split(\",\") | map(select(length > 0))) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_state) = strenv(STATE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_url) = strenv(URL) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .gh_updated_at) = strenv(UPDATED)" \
      "$TASKS_PATH"

    if [ "$STATE" = "closed" ]; then
      CURRENT_STATUS=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .status" "$TASKS_PATH")
      if [ "$CURRENT_STATUS" != "done" ]; then
        NOW=$(now_iso)
        export NOW
        yq -i \
          "(.tasks[] | select(.gh_issue_number == $NUM) | .status) = \"done\" | \
           (.tasks[] | select(.gh_issue_number == $NUM) | .updated_at) = strenv(NOW)" \
          "$TASKS_PATH"
      fi
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
        "title": strenv(TITLE),
        "body": strenv(BODY),
        "labels": (strenv(LABELS_CSV) | split(",") | map(select(length > 0))),
        "status": strenv(STATUS),
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
        "created_at": strenv(NOW),
        "updated_at": strenv(NOW),
        "gh_issue_number": (env(NUM) | tonumber),
        "gh_state": strenv(STATE),
        "gh_url": strenv(URL),
        "gh_updated_at": strenv(UPDATED),
        "dir": strenv(PROJECT_DIR),
        "gh_synced_at": null
      }]' \
      "$TASKS_PATH"
  fi

done

release_lock
