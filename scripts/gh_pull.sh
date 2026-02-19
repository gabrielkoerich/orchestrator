#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
PROJECT_NAME=$(basename "$PROJECT_DIR" .git)
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
  elif [ -n "$PROJECT_DIR" ] && is_bare_repo "$PROJECT_DIR"; then
    REPO=$(git -C "$PROJECT_DIR" config remote.origin.url 2>/dev/null \
      | sed -E 's#^https?://github\.com/##; s#^git@github\.com:##; s#\.git$##' || true)
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

log "[gh_pull] [$PROJECT_NAME] repo=$REPO"

# Fetch open issues only — we don't import closed issues as new tasks
ISSUES_JSON=$(gh_api -X GET "repos/$REPO/issues" --paginate -f state=open -f per_page=100)
# gh api --paginate may return one JSON array per page; merge into one
ISSUES_JSON=$(printf '%s' "$ISSUES_JSON" | yq ea -p=json -o=json -I=0 '[.[]]')
FILTERED=$(printf '%s' "$ISSUES_JSON" | yq -o=json -I=0 'map(select(.pull_request == null))')
if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
  FILTERED=$(printf '%s' "$FILTERED" | yq -o=json -I=0 "map(select(.labels | map(.name) | any_c(. == \"$SYNC_LABEL\")))")
fi

# Check local tasks linked to GitHub issues — mark done if issue was closed
# Uses a single GraphQL batch query instead of N+1 REST calls
OPEN_NUMS=$(printf '%s' "$FILTERED" | yq -r '.[].number')
LOCAL_GH_TASKS=$(yq -r '.tasks[] | select(.gh_issue_number != null and .gh_issue_number != "" and .status != "done") | .gh_issue_number' "$TASKS_PATH" 2>/dev/null || true)
MISSING_NUMS=()
for _GH_NUM in $LOCAL_GH_TASKS; do
  if ! printf '%s\n' "$OPEN_NUMS" | grep -qx "$_GH_NUM"; then
    MISSING_NUMS+=("$_GH_NUM")
  fi
done

if [ ${#MISSING_NUMS[@]} -gt 0 ]; then
  # Build a single GraphQL query to check all missing issues at once
  OWNER=$(printf '%s' "$REPO" | cut -d/ -f1)
  REPO_NAME=$(printf '%s' "$REPO" | cut -d/ -f2)
  GQL_FIELDS=""
  for _num in "${MISSING_NUMS[@]}"; do
    GQL_FIELDS="${GQL_FIELDS} issue_${_num}: issue(number: ${_num}) { number state }"
  done
  GQL_QUERY="query { repository(owner: \"${OWNER}\", name: \"${REPO_NAME}\") { ${GQL_FIELDS} } }"
  BATCH_RESULT=$(gh api graphql -f query="$GQL_QUERY" 2>/dev/null || true)

  for _num in "${MISSING_NUMS[@]}"; do
    _STATE=$(printf '%s' "$BATCH_RESULT" | jq -r ".data.repository.issue_${_num}.state // \"\"" 2>/dev/null || true)
    if [ "$_STATE" = "CLOSED" ]; then
      NOW=$(now_iso)
      export NOW
      yq -i \
        "(.tasks[] | select(.gh_issue_number == $_num) | .status) = \"done\" |
         (.tasks[] | select(.gh_issue_number == $_num) | .gh_state) = \"closed\" |
         (.tasks[] | select(.gh_issue_number == $_num) | .updated_at) = strenv(NOW)" \
        "$TASKS_PATH"
      log "[gh_pull] [$PROJECT_NAME] issue #$_num closed on GitHub — marked task done"
    fi
  done
fi

acquire_lock

trap 'release_lock' EXIT INT TERM

COUNT=$(printf '%s' "$FILTERED" | yq -r 'length')

export LABELS_CSV=""
for i in $([ "$COUNT" -gt 0 ] && seq 0 $((COUNT - 1)) || true); do
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

    # 2-way status sync: if GH was updated after local, derive status from labels
    LOCAL_UPDATED=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .updated_at // \"\"" "$TASKS_PATH")
    if [ -n "$UPDATED" ] && [ -n "$LOCAL_UPDATED" ] && [[ "$UPDATED" > "$LOCAL_UPDATED" ]]; then
      GH_STATUS=""
      for _label in $(printf '%s' "$LABELS_CSV" | tr ',' '\n'); do
        case "$_label" in
          status:new)           GH_STATUS="new" ;;
          status:routed)        GH_STATUS="routed" ;;
          status:in_progress)   GH_STATUS="in_progress" ;;
          status:needs_review)  GH_STATUS="needs_review" ;;
          status:blocked)       GH_STATUS="blocked" ;;
          status:done)          GH_STATUS="done" ;;
        esac
      done
      if [ -n "$GH_STATUS" ]; then
        LOCAL_STATUS=$(yq -r ".tasks[] | select(.gh_issue_number == $NUM) | .status" "$TASKS_PATH")
        if [ "$GH_STATUS" != "$LOCAL_STATUS" ]; then
          NOW=$(now_iso)
          export NOW GH_STATUS
          yq -i \
            "(.tasks[] | select(.gh_issue_number == $NUM) | .status) = strenv(GH_STATUS) | \
             (.tasks[] | select(.gh_issue_number == $NUM) | .updated_at) = strenv(NOW)" \
            "$TASKS_PATH"
          log "[gh_pull] [$PROJECT_NAME] issue #$NUM status synced from GH: $LOCAL_STATUS → $GH_STATUS"
        fi
      fi
    fi

  else
    NEXT_ID=$(yq -r '((.tasks | map(.id) | max) // 0) + 1' "$TASKS_PATH")
    NOW=$(now_iso)
    STATUS="new"
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
        "gh_synced_at": null,
        "gh_last_feedback_at": null
      }]' \
      "$TASKS_PATH"
  fi

done

# --- Owner feedback check ---
# For tasks linked to GitHub issues that are done/in_review/needs_review,
# check if the repo owner has posted new comments (feedback).
REVIEW_OWNER=$(config_get '.workflow.review_owner // ""' | sed 's/^@//')
if [ -z "$REVIEW_OWNER" ] || [ "$REVIEW_OWNER" = "null" ]; then
  REVIEW_OWNER=$(repo_owner "$REPO")
fi

if [ -n "$REVIEW_OWNER" ] && [ "$REVIEW_OWNER" != "null" ]; then
  FEEDBACK_TASKS=$(yq -r \
    ".tasks[] | select(.gh_issue_number != null and .gh_issue_number != \"\" and .dir == \"$PROJECT_DIR\" and (.status == \"done\" or .status == \"in_review\" or .status == \"needs_review\")) | [.id, .gh_issue_number, (.gh_last_feedback_at // .gh_synced_at // \"\")] | @tsv" \
    "$TASKS_PATH" 2>/dev/null || true)

  while IFS=$'\t' read -r _FB_ID _FB_ISSUE _FB_SINCE; do
    [ -z "$_FB_ID" ] && continue

    # Fetch issue comments from owner
    local_feedback=$(fetch_owner_feedback "$REPO" "$_FB_ISSUE" "$REVIEW_OWNER" "$_FB_SINCE")

    # Also check PR comments if task has a branch
    _FB_BRANCH=$(yq -r ".tasks[] | select(.id == $_FB_ID) | .branch // \"\"" "$TASKS_PATH" 2>/dev/null || true)
    if [ -n "$_FB_BRANCH" ] && [ "$_FB_BRANCH" != "null" ]; then
      _FB_PR_NUM=$(gh_api -X GET "repos/${REPO}/pulls" -f head="${REPO%%/*}:${_FB_BRANCH}" -f state=all -q '.[0].number // ""' 2>/dev/null || true)
      if [ -n "$_FB_PR_NUM" ] && [ "$_FB_PR_NUM" != "null" ]; then
        pr_feedback=$(fetch_owner_feedback "$REPO" "$_FB_PR_NUM" "$REVIEW_OWNER" "$_FB_SINCE")
        # Merge issue + PR feedback arrays
        local_feedback=$(printf '%s\n%s' "$local_feedback" "$pr_feedback" | yq ea -p=json -o=json -I=0 '[.[]]' 2>/dev/null || echo "$local_feedback")
      fi
    fi

    # Process if we got any feedback
    fb_count=$(printf '%s' "$local_feedback" | yq -r 'length' 2>/dev/null || echo "0")
    if [ "$fb_count" -gt 0 ]; then
      log "[gh_pull] [$PROJECT_NAME] owner feedback on issue #$_FB_ISSUE for task $_FB_ID ($fb_count comments)"
      process_owner_feedback "$_FB_ID" "$local_feedback"
    fi
  done <<< "$FEEDBACK_TASKS"
fi

release_lock
