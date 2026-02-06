#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_config_file

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
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

SYNC_LABEL=${GITHUB_SYNC_LABEL:-$(config_get '.gh.sync_label // ""')}

ISSUES_JSON=$(gh api "repos/$REPO/issues" --paginate -f state=all -f per_page=100)
FILTERED=$(printf '%s' "$ISSUES_JSON" | yq -o=json -I=0 'map(select(.pull_request == null))')
if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
  FILTERED=$(printf '%s' "$FILTERED" | yq -o=json -I=0 "map(select(.labels | map(.name) | index(\"$SYNC_LABEL\") != null))")
fi

acquire_lock

COUNT=$(printf '%s' "$FILTERED" | yq -r 'length')
for i in $(seq 0 $((COUNT - 1))); do
  NUM=$(printf '%s' "$FILTERED" | yq -r ".[$i].number")
  TITLE=$(printf '%s' "$FILTERED" | yq -r ".[$i].title")
  BODY=$(printf '%s' "$FILTERED" | yq -r ".[$i].body // \"\"")
  LABELS_CSV=$(printf '%s' "$FILTERED" | yq -r ".[$i].labels | map(.name) | join(\",\")")
  STATE=$(printf '%s' "$FILTERED" | yq -r ".[$i].state")
  URL=$(printf '%s' "$FILTERED" | yq -r ".[$i].html_url")
  UPDATED=$(printf '%s' "$FILTERED" | yq -r ".[$i].updated_at")

  EXISTS=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .id" "$TASKS_PATH")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "null" ]; then
    export TITLE BODY LABELS_CSV STATE URL UPDATED
    yq -i \
      "(.tasks[] | select(.gh_issue_number == $NUM) | .title) = env(TITLE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .body) = env(BODY) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .labels) = (env(LABELS_CSV) | split(\",\") | map(select(length > 0))) | \
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
        "labels": (env(LABELS_CSV) | split(",") | map(select(length > 0))),
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
        "gh_synced_at": null
      }]' \
      "$TASKS_PATH"
  fi

done

release_lock
