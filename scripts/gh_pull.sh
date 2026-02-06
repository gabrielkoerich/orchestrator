#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh
init_tasks_file

REPO=${GITHUB_REPO:-$(yq -r '.gh.repo // ""' "$TASKS_PATH")}
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

ISSUES_JSON=$(gh api "repos/$REPO/issues" --paginate -f state=all -f per_page=100)
FILTERED=$(printf '%s' "$ISSUES_JSON" | yq -o=json -I=0 'map(select(.pull_request == null))')

acquire_lock

COUNT=$(printf '%s' "$FILTERED" | yq -r 'length')
for i in $(seq 0 $((COUNT - 1))); do
  NUM=$(printf '%s' "$FILTERED" | yq -r ".[$i].number")
  TITLE=$(printf '%s' "$FILTERED" | yq -r ".[$i].title")
  BODY=$(printf '%s' "$FILTERED" | yq -r ".[$i].body // \"\"")
  LABELS_JSON=$(printf '%s' "$FILTERED" | yq -o=json -I=0 ".[$i].labels | map(.name)")
  STATE=$(printf '%s' "$FILTERED" | yq -r ".[$i].state")
  URL=$(printf '%s' "$FILTERED" | yq -r ".[$i].html_url")
  UPDATED=$(printf '%s' "$FILTERED" | yq -r ".[$i].updated_at")

  EXISTS=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .id" "$TASKS_PATH")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "null" ]; then
    export TITLE BODY LABELS_JSON STATE URL UPDATED
    yq -i \
      "(.tasks[] | select(.gh_issue_number == $NUM) | .title) = env(TITLE) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .body) = env(BODY) | \
       (.tasks[] | select(.gh_issue_number == $NUM) | .labels) = (env(LABELS_JSON) | fromjson) | \
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
    NEXT_ID=$(yq -r '.tasks | map(.id) | max // 0 | . + 1' "$TASKS_PATH")
    NOW=$(now_iso)
    STATUS="new"
    if [ "$STATE" = "closed" ]; then
      STATUS="done"
    fi
    export NEXT_ID TITLE BODY LABELS_JSON STATUS NOW STATE URL UPDATED NUM

    yq -i \
      '.tasks += [{
        "id": (env(NEXT_ID) | tonumber),
        "title": env(TITLE),
        "body": env(BODY),
        "labels": (env(LABELS_JSON) | fromjson),
        "status": env(STATUS),
        "agent": null,
        "agent_profile": null,
        "parent_id": null,
        "children": [],
        "route_reason": null,
        "summary": null,
        "files_changed": [],
        "needs_help": false,
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
