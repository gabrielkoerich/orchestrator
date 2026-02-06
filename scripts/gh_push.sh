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

SKIP_LABELS=("no_gh" "local-only")

TASK_COUNT=$(yq -r '.tasks | length' "$TASKS_PATH")
for i in $(seq 0 $((TASK_COUNT - 1))); do
  ID=$(yq -r ".tasks[$i].id" "$TASKS_PATH")
  TITLE=$(yq -r ".tasks[$i].title" "$TASKS_PATH")
  BODY=$(yq -r ".tasks[$i].body // \"\"" "$TASKS_PATH")
  LABELS_JSON=$(yq -o=json -I=0 ".tasks[$i].labels // []" "$TASKS_PATH")
  STATUS=$(yq -r ".tasks[$i].status" "$TASKS_PATH")
  GH_NUM=$(yq -r ".tasks[$i].gh_issue_number // \"\"" "$TASKS_PATH")
  GH_STATE=$(yq -r ".tasks[$i].gh_state // \"\"" "$TASKS_PATH")
  SUMMARY=$(yq -r ".tasks[$i].summary // \"\"" "$TASKS_PATH")
  FILES_CHANGED_JSON=$(yq -o=json -I=0 ".tasks[$i].files_changed // []" "$TASKS_PATH")
  UPDATED_AT=$(yq -r ".tasks[$i].updated_at // \"\"" "$TASKS_PATH")
  GH_SYNCED_AT=$(yq -r ".tasks[$i].gh_synced_at // \"\"" "$TASKS_PATH")

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

  if [ -z "$GH_NUM" ] || [ "$GH_NUM" = "null" ]; then
    # create issue
    LABEL_ARGS=()
    LABEL_COUNT=$(printf '%s' "$LABELS_JSON" | yq -r 'length')
    for j in $(seq 0 $((LABEL_COUNT - 1))); do
      LBL=$(printf '%s' "$LABELS_JSON" | yq -r ".[$j]")
      LABEL_ARGS+=("-f" "labels[]=$LBL")
    done

    RESP=$(gh api "repos/$REPO/issues" -f title="$TITLE" -f body="$BODY" "${LABEL_ARGS[@]}")
    NUM=$(printf '%s' "$RESP" | yq -r '.number')
    URL=$(printf '%s' "$RESP" | yq -r '.html_url')
    STATE=$(printf '%s' "$RESP" | yq -r '.state')
    NOW=$(now_iso)

    export NUM URL STATE NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_issue_number) = (env(NUM) | tonumber) | \
       (.tasks[] | select(.id == $ID) | .gh_url) = env(URL) | \
       (.tasks[] | select(.id == $ID) | .gh_state) = env(STATE) | \
       (.tasks[] | select(.id == $ID) | .gh_synced_at) = env(NOW)" \
      "$TASKS_PATH"
    continue
  fi

  # Post a comment if summary updated
  if [ -n "$SUMMARY" ] && [ "$UPDATED_AT" != "" ] && [ "$UPDATED_AT" != "$GH_SYNCED_AT" ]; then
    FILES_CHANGED=$(printf '%s' "$FILES_CHANGED_JSON" | yq -r 'join(", ")')
    COMMENT=$(cat <<EOF
Status: $STATUS
Summary: $SUMMARY
Files: $FILES_CHANGED
EOF
)
    gh api "repos/$REPO/issues/$GH_NUM/comments" -f body="$COMMENT" >/dev/null
    NOW=$(now_iso)
    export NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_synced_at) = env(NOW)" \
      "$TASKS_PATH"
  fi

  # Close issue if task done
  if [ "$STATUS" = "done" ] && [ "$GH_STATE" != "closed" ]; then
    gh api "repos/$REPO/issues/$GH_NUM" -X PATCH -f state=closed >/dev/null
    NOW=$(now_iso)
    export NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_state) = \"closed\" | \
       (.tasks[] | select(.id == $ID) | .gh_synced_at) = env(NOW)" \
      "$TASKS_PATH"
  fi

done
