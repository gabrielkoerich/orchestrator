#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_jq
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
ISSUES_JSON=$(printf '%s' "$ISSUES_JSON" | jq -s 'flatten')
FILTERED=$(printf '%s' "$ISSUES_JSON" | jq -c 'map(select(.pull_request == null))')
if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
  FILTERED=$(printf '%s' "$FILTERED" | jq -c --arg label "$SYNC_LABEL" 'map(select(.labels | map(.name) | any(. == $label)))')
fi

# Check local tasks linked to GitHub issues — mark done if issue was closed
OPEN_NUMS=$(printf '%s' "$FILTERED" | jq -r '.[].number')
LOCAL_GH_TASKS=$(db_scalar "SELECT gh_issue_number FROM tasks
  WHERE gh_issue_number IS NOT NULL AND gh_issue_number != '' AND status != 'done';" 2>/dev/null || true)
MISSING_NUMS=()
for _GH_NUM in $LOCAL_GH_TASKS; do
  if ! printf '%s\n' "$OPEN_NUMS" | grep -qx "$_GH_NUM"; then
    MISSING_NUMS+=("$_GH_NUM")
  fi
done

if [ ${#MISSING_NUMS[@]} -gt 0 ]; then
  OWNER=$(printf '%s' "$REPO" | cut -d/ -f1)
  REPO_NAME=$(printf '%s' "$REPO" | cut -d/ -f2)
  GQL_FIELDS=""
  for _num in "${MISSING_NUMS[@]}"; do
    GQL_FIELDS="${GQL_FIELDS} issue_${_num}: issue(number: ${_num}) { number state }"
  done
  GQL_QUERY="query { repository(owner: \"${OWNER}\", name: \"${REPO_NAME}\") { ${GQL_FIELDS} } }"
  BATCH_RESULT=$(gh_api graphql -f query="$GQL_QUERY" 2>/dev/null || true)

  for _num in "${MISSING_NUMS[@]}"; do
    _STATE=$(printf '%s' "$BATCH_RESULT" | jq -r ".data.repository.issue_${_num}.state // \"\"" 2>/dev/null || true)
    if [ "$_STATE" = "CLOSED" ]; then
      _TASK_ID=$(db_task_id_by_gh_issue "$_num")
      if [ -n "$_TASK_ID" ]; then
        db_task_update "$_TASK_ID" "status=done" "gh_state=closed"
        log "[gh_pull] [$PROJECT_NAME] issue #$_num closed on GitHub — marked task done"
      fi
    fi
  done
fi

COUNT=$(printf '%s' "$FILTERED" | jq -r 'length')

for i in $([ "$COUNT" -gt 0 ] && seq 0 $((COUNT - 1)) || true); do
  NUM=$(printf '%s' "$FILTERED" | jq -r ".[$i].number")
  TITLE=$(printf '%s' "$FILTERED" | jq -r ".[$i].title")
  BODY=$(printf '%s' "$FILTERED" | jq -r ".[$i].body // \"\"")
  LABELS_CSV=$(printf '%s' "$FILTERED" | jq -r ".[$i].labels | map(.name) | join(\",\")")
  LABELS_CSV=${LABELS_CSV:-""}
  STATE=$(printf '%s' "$FILTERED" | jq -r ".[$i].state")
  STATE_LOWER=$(printf '%s' "$STATE" | tr '[:upper:]' '[:lower:]')
  URL=$(printf '%s' "$FILTERED" | jq -r ".[$i].html_url")
  UPDATED=$(printf '%s' "$FILTERED" | jq -r ".[$i].updated_at")

  EXISTS=$(db_task_id_by_gh_issue "$NUM")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "null" ]; then
    # Skip updating tasks that are already done with closed issues
    EXISTING_STATUS=$(db_task_field "$EXISTS" "status")
    if [ "$EXISTING_STATUS" = "done" ] && [ "$STATE_LOWER" = "closed" ]; then
      continue
    fi

    # Save local updated_at BEFORE db_task_update bumps it
    LOCAL_UPDATED=$(db_task_field "$EXISTS" "updated_at")

    # Update existing task
    db_task_update "$EXISTS" \
      "title=$TITLE" \
      "body=$BODY" \
      "gh_state=$STATE_LOWER" \
      "gh_url=$URL" \
      "gh_updated_at=$UPDATED"
    # Update labels
    db_set_labels "$EXISTS" "$LABELS_CSV"

    # 2-way status sync: if GH was updated after local, derive status from labels
    # Only allow status to move forward (ratchet), never backwards.
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
        LOCAL_STATUS=$(db_task_field "$EXISTS" "status")
        if [ "$GH_STATUS" != "$LOCAL_STATUS" ]; then
          # Status rank: higher number = further along in the workflow
          _status_rank() {
            case "$1" in
              new)           echo 0 ;;
              routed)        echo 1 ;;
              in_progress)   echo 2 ;;
              needs_review)  echo 3 ;;
              blocked)       echo 3 ;;
              in_review)     echo 4 ;;
              done)          echo 5 ;;
              *)             echo 0 ;;
            esac
          }
          GH_RANK=$(_status_rank "$GH_STATUS")
          LOCAL_RANK=$(_status_rank "$LOCAL_STATUS")
          if [ "$GH_RANK" -ge "$LOCAL_RANK" ]; then
            db_task_update "$EXISTS" "status=$GH_STATUS"
            log "[gh_pull] [$PROJECT_NAME] issue #$NUM status synced from GH: $LOCAL_STATUS → $GH_STATUS"
          fi
        fi
      fi
    fi

  else
    # Create new task from GitHub issue
    NEW_ID=$(db_create_task_from_gh "$TITLE" "$BODY" "$LABELS_CSV" "$NUM" "$STATE_LOWER" "$URL" "$UPDATED" "$PROJECT_DIR")
    log "[gh_pull] [$PROJECT_NAME] created task $NEW_ID from issue #$NUM"
  fi

done

# --- Owner feedback check ---
REVIEW_OWNER=$(config_get '.workflow.review_owner // ""' | sed 's/^@//')
if [ -z "$REVIEW_OWNER" ] || [ "$REVIEW_OWNER" = "null" ]; then
  REVIEW_OWNER=$(repo_owner "$REPO")
fi

if [ -n "$REVIEW_OWNER" ] && [ "$REVIEW_OWNER" != "null" ]; then
  FEEDBACK_TASKS=$(db_row "SELECT id, gh_issue_number, COALESCE(gh_last_feedback_at, gh_synced_at, '') FROM tasks
    WHERE gh_issue_number IS NOT NULL AND gh_issue_number != ''
      AND dir = '$(sql_escape "$PROJECT_DIR")'
      AND status IN ('done', 'in_review', 'needs_review')
    ORDER BY id;" 2>/dev/null || true)

  while IFS=$'\x1f' read -r _FB_ID _FB_ISSUE _FB_SINCE; do
    [ -z "$_FB_ID" ] && continue

    local_feedback=$(fetch_owner_feedback "$REPO" "$_FB_ISSUE" "$REVIEW_OWNER" "$_FB_SINCE")

    # Also check PR comments if task has a branch
    _FB_BRANCH=$(db_task_field "$_FB_ID" "branch")
    if [ -n "$_FB_BRANCH" ] && [ "$_FB_BRANCH" != "null" ]; then
      _FB_PR_NUM=$(gh_api -X GET "repos/${REPO}/pulls" -f head="${REPO%%/*}:${_FB_BRANCH}" -f state=all -q '.[0].number // ""' 2>/dev/null || true)
      if [ -n "$_FB_PR_NUM" ] && [ "$_FB_PR_NUM" != "null" ]; then
        pr_feedback=$(fetch_owner_feedback "$REPO" "$_FB_PR_NUM" "$REVIEW_OWNER" "$_FB_SINCE")
        local_feedback=$(printf '%s\n%s' "$local_feedback" "$pr_feedback" | jq -s 'flatten' 2>/dev/null || echo "$local_feedback")
      fi
    fi

    fb_count=$(printf '%s' "$local_feedback" | jq -r 'length' 2>/dev/null || echo "0")
    if [ "$fb_count" -gt 0 ]; then
      log "[gh_pull] [$PROJECT_NAME] owner feedback on issue #$_FB_ISSUE for task $_FB_ID ($fb_count comments)"
      process_owner_feedback "$_FB_ID" "$local_feedback"
    fi
  done <<< "$FEEDBACK_TASKS"
fi
