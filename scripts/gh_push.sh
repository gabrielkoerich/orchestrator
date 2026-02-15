#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
require_jq
init_config_file
load_project_config

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
STATUS_LABEL_PREFIX=${GITHUB_STATUS_LABEL_PREFIX:-"status:"}
GH_BACKOFF_MODE=${GITHUB_BACKOFF_MODE:-$(config_get '.gh.backoff.mode // "wait"')}
GH_BACKOFF_BASE_SECONDS=${GITHUB_BACKOFF_BASE_SECONDS:-$(config_get '.gh.backoff.base_seconds // 30')}
GH_BACKOFF_MAX_SECONDS=${GITHUB_BACKOFF_MAX_SECONDS:-$(config_get '.gh.backoff.max_seconds // 900')}
export GH_BACKOFF_MODE GH_BACKOFF_BASE_SECONDS GH_BACKOFF_MAX_SECONDS

PROJECT_ID=${GITHUB_PROJECT_ID:-$(config_get '.gh.project_id // ""')}
PROJECT_STATUS_FIELD_ID=${GITHUB_PROJECT_STATUS_FIELD_ID:-$(config_get '.gh.project_status_field_id // ""')}
PROJECT_STATUS_MAP_JSON=${GITHUB_PROJECT_STATUS_MAP_JSON:-}
if [ -z "$PROJECT_STATUS_MAP_JSON" ]; then
  PROJECT_STATUS_MAP_JSON=$(yq -o=json -I=0 '.gh.project_status_map // {}' "$CONFIG_PATH")
fi

AUTO_CLOSE=${AUTO_CLOSE:-$(config_get '.workflow.auto_close // true')}
REVIEW_OWNER=${REVIEW_OWNER:-$(config_get '.workflow.review_owner // ""')}

SKIP_LABELS=("no_gh" "local-only")

map_status_to_project() {
  local status="$1"
  case "$status" in
    new|routed)
      echo "backlog"
      ;;
    in_progress|blocked)
      echo "in_progress"
      ;;
    needs_review)
      echo "review"
      ;;
    done)
      echo "done"
      ;;
    *)
      echo "backlog"
      ;;
  esac
}

sync_project_status() {
  local issue_number="$1"
  local status="$2"

  if [ -z "$PROJECT_ID" ] || [ -z "$PROJECT_STATUS_FIELD_ID" ] || [ -z "$PROJECT_STATUS_MAP_JSON" ]; then
    return 0
  fi

  local key
  key=$(map_status_to_project "$status")

  local option_id
  option_id=$(printf '%s' "$PROJECT_STATUS_MAP_JSON" | yq -r ".\"$key\" // \"\"")
  if [ -z "$option_id" ] || [ "$option_id" = "null" ]; then
    return 0
  fi

  local issue_node
  issue_node=$(gh_api "repos/$REPO/issues/$issue_number" -q .node_id)

  local items_json
  items_json=$(gh_api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { items(first:100){ nodes{ id content{ ... on Issue { id } } } } } } }' -f project="$PROJECT_ID")

  local item_id
  item_id=$(printf '%s' "$items_json" | yq -r ".data.node.items.nodes[] | select(.content.id == \"$issue_node\") | .id" | head -n1)
  if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
    # Issue not in project — add it
    local add_json
    add_json=$(gh_api graphql \
      -f query='mutation($project:ID!,$contentId:ID!){ addProjectV2ItemById(input:{projectId:$project, contentId:$contentId}){ item{ id } } }' \
      -f project="$PROJECT_ID" \
      -f contentId="$issue_node" 2>/dev/null || true)
    item_id=$(printf '%s' "$add_json" | yq -r '.data.addProjectV2ItemById.item.id // ""' 2>/dev/null)
    if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
      return 0
    fi
    echo "[gh_push] added issue #$issue_number to project"
  fi

  gh_api graphql -f query='mutation($project:ID!, $item:ID!, $field:ID!, $option:ID!){ updateProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field, value:{singleSelectOptionId:$option}}){ projectV2Item{id} } }' \
    -f project="$PROJECT_ID" -f item="$item_id" -f field="$PROJECT_STATUS_FIELD_ID" -f option="$option_id" >/dev/null
}

TASK_COUNT=$(yq -r '.tasks | length' "$TASKS_PATH")
if [ "$TASK_COUNT" -le 0 ]; then
  exit 0
fi

DIRTY_COUNT=$(yq -r '
  [.tasks[] | select(
    (.gh_issue_number == null or .gh_issue_number == "") or
    (.updated_at != .gh_synced_at)
  )] | length
' "$TASKS_PATH")
if [ "$DIRTY_COUNT" -le 0 ]; then
  exit 0
fi
for i in $(seq 0 $((TASK_COUNT - 1))); do
  ID=$(yq -r ".tasks[$i].id" "$TASKS_PATH")
  TITLE=$(yq -r ".tasks[$i].title" "$TASKS_PATH")
  BODY=$(yq -r ".tasks[$i].body // \"\"" "$TASKS_PATH")
  LABELS_JSON=$(yq -o=json -I=0 ".tasks[$i].labels // []" "$TASKS_PATH")
  STATUS=$(yq -r ".tasks[$i].status" "$TASKS_PATH")
  GH_NUM=$(yq -r ".tasks[$i].gh_issue_number // \"\"" "$TASKS_PATH")
  GH_STATE=$(yq -r ".tasks[$i].gh_state // \"\"" "$TASKS_PATH")
  SUMMARY=$(yq -r ".tasks[$i].summary // \"\"" "$TASKS_PATH")
  REASON=$(yq -r ".tasks[$i].reason // \"\"" "$TASKS_PATH")
  ACCOMPLISHED=$(yq -r ".tasks[$i].accomplished // [] | join(\", \" )" "$TASKS_PATH")
  REMAINING=$(yq -r ".tasks[$i].remaining // [] | join(\", \" )" "$TASKS_PATH")
  BLOCKERS=$(yq -r ".tasks[$i].blockers // [] | join(\", \" )" "$TASKS_PATH")
  FILES_CHANGED_JSON=$(yq -o=json -I=0 ".tasks[$i].files_changed // []" "$TASKS_PATH")
  LAST_ERROR=$(yq -r ".tasks[$i].last_error // \"\"" "$TASKS_PATH")
  ATTEMPTS=$(yq -r ".tasks[$i].attempts // 0" "$TASKS_PATH")
  UPDATED_AT=$(yq -r ".tasks[$i].updated_at // \"\"" "$TASKS_PATH")
  GH_SYNCED_AT=$(yq -r ".tasks[$i].gh_synced_at // \"\"" "$TASKS_PATH")

  echo "[gh_push] task id=$ID status=$STATUS title=$(printf '%s' "$TITLE" | head -c 80)"

  skip=false
  for lbl in "${SKIP_LABELS[@]}"; do
    if printf '%s' "$LABELS_JSON" | yq -r "index(\"$lbl\")" >/dev/null 2>&1; then
      if [ "$(printf '%s' "$LABELS_JSON" | yq -r "index(\"$lbl\")")" != "null" ]; then
        skip=true
        break
      fi
    fi
  done
  if [ "$skip" = true ]; then
    continue
  fi

  if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
    if [ "$(printf '%s' "$LABELS_JSON" | yq -r "index(\"$SYNC_LABEL\")")" = "null" ]; then
      continue
    fi
  fi

  STATUS_LABEL="${STATUS_LABEL_PREFIX}${STATUS}"
  export STATUS_LABEL STATUS_LABEL_PREFIX
  LABELS_FOR_GH=$(printf '%s' "$LABELS_JSON" | jq -c --arg prefix "$STATUS_LABEL_PREFIX" --arg status "$STATUS_LABEL" \
    'map(select(startswith($prefix) | not)) + [$status]')

  if [ -z "$GH_NUM" ] || [ "$GH_NUM" = "null" ]; then
    if [ -z "$TITLE" ] || [ "$TITLE" = "null" ]; then
      echo "Skipping task $ID: missing title; cannot create GitHub issue." >&2
      continue
    fi
    # create issue
    LABEL_ARGS=()
    LABEL_COUNT=$(printf '%s' "$LABELS_FOR_GH" | yq -r 'length')
    for j in $(seq 0 $((LABEL_COUNT - 1))); do
      LBL=$(printf '%s' "$LABELS_FOR_GH" | yq -r ".[$j]")
      LABEL_ARGS+=("-f" "labels[]=$LBL")
    done

    RESP=$(gh_api "repos/$REPO/issues" -f title="$TITLE" -f body="$BODY" "${LABEL_ARGS[@]}")
    NUM=$(printf '%s' "$RESP" | yq -r '.number')
    URL=$(printf '%s' "$RESP" | yq -r '.html_url')
    STATE=$(printf '%s' "$RESP" | yq -r '.state')
    NOW=$(now_iso)

    export NUM URL STATE NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_issue_number) = (env(NUM) | tonumber) | \
       (.tasks[] | select(.id == $ID) | .gh_url) = strenv(URL) | \
       (.tasks[] | select(.id == $ID) | .gh_state) = strenv(STATE) | \
       (.tasks[] | select(.id == $ID) | .gh_synced_at) = strenv(NOW)" \
      "$TASKS_PATH"

    sync_project_status "$NUM" "$STATUS"
    continue
  fi

  # Ensure issue labels reflect status only when task changed
  if [ "$UPDATED_AT" = "$GH_SYNCED_AT" ]; then
    sync_project_status "$GH_NUM" "$STATUS"
    continue
  fi

  LABEL_ARGS=()
  LABEL_COUNT=$(printf '%s' "$LABELS_FOR_GH" | yq -r 'length')
  for j in $(seq 0 $((LABEL_COUNT - 1))); do
    LBL=$(printf '%s' "$LABELS_FOR_GH" | yq -r ".[$j]")
    LABEL_ARGS+=("-f" "labels[]=$LBL")
  done
  gh_api "repos/$REPO/issues/$GH_NUM" -X PATCH "${LABEL_ARGS[@]}" >/dev/null
  NOW=$(now_iso)
  export NOW
  with_lock yq -i \
    "(.tasks[] | select(.id == $ID) | .gh_synced_at) = strenv(NOW)" \
    "$TASKS_PATH"

  # Post a comment if task updated
  if [ "$UPDATED_AT" != "" ] && [ "$UPDATED_AT" != "$GH_SYNCED_AT" ]; then
    FILES_CHANGED=$(printf '%s' "$FILES_CHANGED_JSON" | yq -r 'join(", ")')
    OWNER_TAG="@$(repo_owner "$REPO")"

    if [ "$STATUS" = "blocked" ] || [ "$STATUS" = "needs_review" ]; then
      # Detailed comment for stuck/blocked tasks, tagging the repo owner
      COMMENT="## Agent needs help"
      COMMENT="$COMMENT

**Status:** \`$STATUS\`"
      if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
        COMMENT="$COMMENT
**Summary:** $SUMMARY"
      fi
      if [ -n "$REASON" ] && [ "$REASON" != "null" ]; then
        COMMENT="$COMMENT
**Reason:** $REASON"
      fi
      if [ -n "$LAST_ERROR" ] && [ "$LAST_ERROR" != "null" ]; then
        COMMENT="$COMMENT
**Error:** $LAST_ERROR"
      fi
      if [ -n "$BLOCKERS" ]; then
        COMMENT="$COMMENT
**Blockers:** $BLOCKERS"
      fi
      if [ -n "$ACCOMPLISHED" ]; then
        COMMENT="$COMMENT
**Accomplished so far:** $ACCOMPLISHED"
      fi
      if [ -n "$REMAINING" ]; then
        COMMENT="$COMMENT
**Remaining:** $REMAINING"
      fi
      if [ -n "$FILES_CHANGED" ]; then
        COMMENT="$COMMENT
**Files changed:** $FILES_CHANGED"
      fi
      COMMENT="$COMMENT
**Attempts:** $ATTEMPTS

${OWNER_TAG} — this task needs your attention."
      gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="$COMMENT" >/dev/null
    elif [ -n "$SUMMARY" ]; then
      # Standard progress/completion comment
      COMMENT="**Status:** \`$STATUS\`
**Summary:** $SUMMARY"
      if [ -n "$ACCOMPLISHED" ]; then
        COMMENT="$COMMENT
**Accomplished:** $ACCOMPLISHED"
      fi
      if [ -n "$REMAINING" ]; then
        COMMENT="$COMMENT
**Remaining:** $REMAINING"
      fi
      if [ -n "$FILES_CHANGED" ]; then
        COMMENT="$COMMENT
**Files:** $FILES_CHANGED"
      fi
      gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="$COMMENT" >/dev/null
    fi

    NOW=$(now_iso)
    export NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_synced_at) = strenv(NOW)" \
      "$TASKS_PATH"
  fi

  # Review/close behavior
  if [ "$STATUS" = "done" ] && [ "$AUTO_CLOSE" != "true" ]; then
    OWNER_TAG="@$(repo_owner "$REPO")"
    if [ -n "$OWNER_TAG" ] && [ "$OWNER_TAG" != "@" ]; then
      gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="Review requested ${OWNER_TAG}" >/dev/null
    elif [ -n "$REVIEW_OWNER" ]; then
      gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="Review requested ${REVIEW_OWNER}" >/dev/null
    fi
    sync_project_status "$GH_NUM" "needs_review"
  fi

  # Close issue if task done and auto_close
  if [ "$STATUS" = "done" ] && [ "$GH_STATE" != "closed" ] && [ "$AUTO_CLOSE" = "true" ]; then
    gh_api "repos/$REPO/issues/$GH_NUM" -X PATCH -f state=closed >/dev/null
    NOW=$(now_iso)
    export NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_state) = \"closed\" | \
       (.tasks[] | select(.id == $ID) | .gh_synced_at) = strenv(NOW)" \
      "$TASKS_PATH"
  fi

  sync_project_status "$GH_NUM" "$STATUS"

done
