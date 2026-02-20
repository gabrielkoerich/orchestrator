#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_jq
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
PROJECT_NAME=$(basename "$PROJECT_DIR" .git)
init_config_file
load_project_config

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh

REPO=${GITHUB_REPO:-$(config_get '.gh.repo // ""')}
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  log_err "[gh_push] no repo configured. Run 'orchestrator init' first."
  exit 1
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
  PROJECT_STATUS_MAP_JSON=$(yq -o=json -r '.gh.project_status_map // {}' "$CONFIG_PATH" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')
fi

SKIP_LABELS=("no_gh" "local-only")

agent_badge() {
  local agent="${1:-orchestrator}"
  case "$agent" in
    claude)  echo "🤖 🟣 Claude" ;;
    codex)   echo "🤖 🟢 Codex" ;;
    opencode) echo "🤖 🔵 OpenCode" ;;
    *)       echo "🤖 $agent" ;;
  esac
}

# Read the saved prompt file for a task, truncated to keep comments under GitHub limits.
read_prompt_file() {
  local task_dir="$1" task_id="$2"
  local state_dir="${task_dir:+${task_dir}/.orchestrator}"
  state_dir="${state_dir:-${STATE_DIR:-.orchestrator}}"
  local prompt_file="${state_dir}/prompt-${task_id}.txt"
  if [ -f "$prompt_file" ]; then
    head -c 10000 "$prompt_file"
  fi
}

# Build a condensed tool activity summary from tools-{ID}.json
read_tool_summary() {
  local task_dir="$1" task_id="$2"
  local state_dir="${task_dir:+${task_dir}/.orchestrator}"
  state_dir="${state_dir:-${STATE_DIR:-.orchestrator}}"
  local tools_file="${state_dir}/tools-${task_id}.json"
  if [ ! -f "$tools_file" ] || [ ! -s "$tools_file" ]; then return; fi

  python3 - "$tools_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        history = json.load(f)
except Exception:
    sys.exit(0)
if not history:
    sys.exit(0)

counts = {}
errors = []
for h in history:
    tool = h.get("tool", "?")
    counts[tool] = counts.get(tool, 0) + 1
    if h.get("error"):
        inp = h.get("input", {})
        if tool == "Bash":
            detail = inp.get("command", "?")[:120]
        elif tool in ("Edit", "Write", "Read"):
            detail = inp.get("file_path", "?")
        else:
            detail = tool
        errors.append(f"- `{detail}`")

lines = ["| Tool | Calls |", "|------|-------|"]
for tool in sorted(counts, key=lambda t: -counts[t]):
    lines.append(f"| {tool} | {counts[tool]} |")
print("\n".join(lines))

if errors:
    print("")
    print(f"<details><summary>Failed tool calls ({len(errors)})</summary>")
    print("")
    print("\n".join(errors[:10]))
    print("")
    print("</details>")
PY
}

map_status_to_project() {
  local status="$1"
  case "$status" in
    new|routed)
      echo "backlog"
      ;;
    in_progress|blocked)
      echo "in_progress"
      ;;
    in_review|needs_review)
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
  option_id=$(printf '%s' "$PROJECT_STATUS_MAP_JSON" | jq -r ".\"$key\" // \"\"")
  if [ -z "$option_id" ] || [ "$option_id" = "null" ]; then
    return 0
  fi

  local issue_node
  issue_node=$(gh_api "repos/$REPO/issues/$issue_number" -q .node_id)

  local items_json
  items_json=$(gh_api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { items(first:100){ nodes{ id content{ ... on Issue { id } } } } } } }' -f project="$PROJECT_ID")

  local item_id
  item_id=$(printf '%s' "$items_json" | jq -r ".data.node.items.nodes[] | select(.content.id == \"$issue_node\") | .id" | head -n1)
  if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
    # Issue not in project — add it
    local add_json
    add_json=$(gh_api graphql \
      -f query='mutation($project:ID!,$contentId:ID!){ addProjectV2ItemById(input:{projectId:$project, contentId:$contentId}){ item{ id } } }' \
      -f project="$PROJECT_ID" \
      -f contentId="$issue_node" 2>/dev/null || true)
    item_id=$(printf '%s' "$add_json" | jq -r '.data.addProjectV2ItemById.item.id // ""' 2>/dev/null)
    if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
      return 0
    fi
    log "[gh_push] added issue #$issue_number to project"
  fi

  gh_api graphql -f query='mutation($project:ID!, $item:ID!, $field:ID!, $option:String!){ updateProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field, value:{singleSelectOptionId:$option}}){ projectV2Item{id} } }' \
    -f project="$PROJECT_ID" -f item="$item_id" -f field="$PROJECT_STATUS_FIELD_ID" -f option="$option_id" >/dev/null
}

archive_project_item() {
  local project_id="$1" item_id="$2"
  gh_api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!) {
      archiveProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
        item { id }
      }
    }
  ' -f projectId="$project_id" -f itemId="$item_id" 2>/dev/null || true
}

# Ensure a label exists on the repo (create with color if missing).
ensure_label() {
  local name="$1" color="${2:-ededed}" description="${3:-}"
  local encoded
  encoded=$(printf '%s' "$name" | jq -sRr @uri)
  local existing
  existing=$(gh_api "repos/$REPO/labels/$encoded" 2>/dev/null || true)
  if [ -z "$existing" ]; then
    gh_api "repos/$REPO/labels" \
      -f name="$name" -f color="$color" -f description="$description" >/dev/null 2>&1 || true
  else
    local current_color
    current_color=$(printf '%s' "$existing" | jq -r '.color // ""')
    if [ "$current_color" != "$color" ]; then
      gh_api "repos/$REPO/labels/$encoded" -X PATCH \
        -f color="$color" >/dev/null 2>&1 || true
    fi
  fi
}

# ============================================================
# Main sync loop
# ============================================================

TASK_COUNT=$(db_total_task_count)
if [ "$TASK_COUNT" -le 0 ]; then
  exit 0
fi

DIRTY_COUNT=$(db_dirty_task_count)
# Always run the loop if project board is configured (status may need syncing)
if [ "$DIRTY_COUNT" -le 0 ] && [ -z "$PROJECT_ID" ]; then
  exit 0
fi

ALL_IDS=$(db_all_task_ids)
[ -z "$ALL_IDS" ] && exit 0

while IFS= read -r ID; do
  [ -n "$ID" ] || continue

  # Load all task fields into shell variables
  db_load_task "$ID" || continue

  STATUS="$TASK_STATUS"
  TITLE="$TASK_TITLE"
  BODY="$TASK_BODY"
  AGENT="$TASK_AGENT"
  AGENT_MODEL_VAL="$AGENT_MODEL"
  GH_NUM="$GH_ISSUE_NUMBER"
  GH_STATE=$(printf '%s' "$TASK_GH_STATE" | tr '[:upper:]' '[:lower:]')
  GH_PROJECT_ITEM_ID="$TASK_GH_PROJECT_ITEM_ID"
  GH_ARCHIVED="$TASK_GH_ARCHIVED"
  SUMMARY="$TASK_SUMMARY"
  REASON="$TASK_REASON"
  LAST_ERROR="$TASK_LAST_ERROR"
  PARENT_ID="$TASK_PARENT_ID"
  PROMPT_HASH="$TASK_PROMPT_HASH"
  TASK_DIR_VAL="$TASK_DIR"
  ATTEMPTS_VAL="$ATTEMPTS"
  DURATION="$TASK_DURATION"
  INPUT_TOKENS="$TASK_INPUT_TOKENS"
  OUTPUT_TOKENS="$TASK_OUTPUT_TOKENS"
  STDERR_SNIPPET="$TASK_STDERR_SNIPPET"
  UPDATED_AT="$TASK_UPDATED_AT"
  GH_SYNCED_AT="$TASK_GH_SYNCED_AT"
  GH_SYNCED_STATUS="$TASK_GH_SYNCED_STATUS"

  # Get array fields
  ACCOMPLISHED_LIST=$(db_task_accomplished_list "$ID")
  REMAINING_LIST=$(db_task_remaining_list "$ID")
  BLOCKERS_LIST=$(db_task_blockers_list "$ID")
  FILES_CHANGED_LIST=$(db_task_files_list "$ID")

  # Get labels as JSON array for GitHub API
  LABELS_JSON=$(db_task_labels_json "$ID")

  # Only sync tasks that belong to the current project.
  # Tasks from other projects (different dir) are handled when gh_push runs for that project.
  if [ -n "$TASK_DIR_VAL" ] && [ "$TASK_DIR_VAL" != "null" ] && [ "$TASK_DIR_VAL" != "$PROJECT_DIR" ]; then
    # Check if this task's dir is under the current project (worktree)
    TASK_PROJECT_DIR=$(cd "$TASK_DIR_VAL" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/.git$||' || echo "$TASK_DIR_VAL")
    if [ "$TASK_PROJECT_DIR" != "$PROJECT_DIR" ]; then
      continue
    fi
  fi

  log "[gh_push] [$PROJECT_NAME] task id=$ID status=$STATUS title=$(printf '%s' "$TITLE" | head -c 80)"

  # Skip done tasks that already have a GitHub issue — nothing to create or update
  if [ "$STATUS" = "done" ] && [ -n "$GH_NUM" ] && [ "$GH_NUM" != "null" ]; then
    if [ "${GH_ARCHIVED:-0}" != "1" ] && [ -n "${GH_PROJECT_ITEM_ID:-}" ] && [ "$GH_PROJECT_ITEM_ID" != "null" ] && [ -n "${PROJECT_ID:-}" ]; then
      archive_project_item "$PROJECT_ID" "$GH_PROJECT_ITEM_ID"
      db_task_set "$ID" "gh_archived" "1"
      log "[gh_push] [$PROJECT_NAME] task=$ID archived project item $GH_PROJECT_ITEM_ID"
    fi
    if [ "$UPDATED_AT" != "$GH_SYNCED_AT" ] || [ "$STATUS" != "$GH_SYNCED_STATUS" ]; then
      db_task_set_synced "$ID" "$STATUS"
    fi
    continue
  fi

  # Skip tasks with no_gh or local-only labels
  skip=false
  for lbl in "${SKIP_LABELS[@]}"; do
    if db_task_has_label "$ID" "$lbl"; then
      skip=true
      break
    fi
  done
  if [ "$skip" = true ]; then
    continue
  fi

  if [ -n "$SYNC_LABEL" ] && [ "$SYNC_LABEL" != "null" ]; then
    if ! db_task_has_label "$ID" "$SYNC_LABEL"; then
      # Still sync board status even if task doesn't have sync label
      if [ -n "$GH_NUM" ] && [ "$GH_NUM" != "null" ] && [ "$STATUS" != "$GH_SYNCED_STATUS" ]; then
        sync_project_status "$GH_NUM" "$STATUS"
        db_task_update "$ID" "gh_synced_status=$STATUS"
      fi
      continue
    fi
  fi

  STATUS_LABEL="${STATUS_LABEL_PREFIX}${STATUS}"
  # Ensure status label exists with a color
  case "$STATUS" in
    new)           ensure_label "$STATUS_LABEL" "0e8a16" "Task is new" ;;
    routed)        ensure_label "$STATUS_LABEL" "1d76db" "Task has been routed to an agent" ;;
    in_progress)   ensure_label "$STATUS_LABEL" "fbca04" "Agent is working on this task" ;;
    done)          ensure_label "$STATUS_LABEL" "0e8a16" "Task is completed" ;;
    blocked)       ensure_label "$STATUS_LABEL" "d73a4a" "Task is blocked" ;;
    in_review)     ensure_label "$STATUS_LABEL" "0075ca" "PR open, awaiting merge" ;;
    needs_review)  ensure_label "$STATUS_LABEL" "e4e669" "Task needs human review" ;;
    *)             ensure_label "$STATUS_LABEL" "c5def5" "" ;;
  esac

  # Build labels for GitHub: existing labels minus old status + new status
  LABELS_FOR_GH=$(printf '%s' "$LABELS_JSON" | jq -c --arg prefix "$STATUS_LABEL_PREFIX" --arg status "$STATUS_LABEL" \
    'map(select(startswith($prefix) | not)) + [$status]')

  if [ -z "$GH_NUM" ] || [ "$GH_NUM" = "null" ]; then
    if [ -z "$TITLE" ] || [ "$TITLE" = "null" ]; then
      log_err "Skipping task $ID: missing title; cannot create GitHub issue." >&2
      continue
    fi
    # Never create new issues for already-done tasks
    if [ "$STATUS" = "done" ]; then
      db_task_set_synced "$ID" "$STATUS"
      continue
    fi
    # Create issue
    LABEL_ARGS=()
    for lbl in $(printf '%s' "$LABELS_FOR_GH" | jq -r '.[]'); do
      LABEL_ARGS+=("-f" "labels[]=$lbl")
    done

    RESP=$(gh_api "repos/$REPO/issues" -f title="$TITLE" -f body="$BODY" "${LABEL_ARGS[@]}")
    NUM=$(printf '%s' "$RESP" | jq -r '.number')
    URL=$(printf '%s' "$RESP" | jq -r '.html_url')
    STATE=$(printf '%s' "$RESP" | jq -r '.state')

    db_task_update "$ID" \
      "gh_issue_number=$NUM" \
      "gh_url=$URL" \
      "gh_state=$STATE"
    db_task_set_synced "$ID" "$STATUS"

    log "[gh_push] [$PROJECT_NAME] task=$ID created issue #$NUM"

    # Link as sub-issue if task has a parent with a GitHub issue
    if [ -n "$PARENT_ID" ] && [ "$PARENT_ID" != "null" ]; then
      PARENT_GH_NUM=$(db_task_field "$PARENT_ID" "gh_issue_number")
      if [ -n "$PARENT_GH_NUM" ] && [ "$PARENT_GH_NUM" != "null" ] && [ "$PARENT_GH_NUM" != "0" ]; then
        PARENT_NODE_ID=$(gh_api "repos/$REPO/issues/$PARENT_GH_NUM" -q '.node_id' 2>/dev/null || true)
        CHILD_NODE_ID=$(gh_api "repos/$REPO/issues/$NUM" -q '.node_id' 2>/dev/null || true)
        if [ -n "$PARENT_NODE_ID" ] && [ -n "$CHILD_NODE_ID" ]; then
          gh api graphql \
            -H GraphQL-Features:sub_issues \
            -f parentIssueId="$PARENT_NODE_ID" \
            -f childIssueId="$CHILD_NODE_ID" \
            -f query='mutation($parentIssueId: ID!, $childIssueId: ID!) {
              addSubIssue(input: {issueId: $parentIssueId, subIssueId: $childIssueId}) {
                issue { number }
                subIssue { number }
              }
            }' >/dev/null 2>&1 || log_err "[gh_push] task=$ID failed to link as sub-issue of #$PARENT_GH_NUM"
          log "[gh_push] [$PROJECT_NAME] task=$ID linked #$NUM as sub-issue of #$PARENT_GH_NUM"
        fi
      fi
    fi

    if [ "$STATUS" != "$GH_SYNCED_STATUS" ]; then
      sync_project_status "$NUM" "$STATUS"
      db_task_update "$ID" "gh_synced_status=$STATUS"
    fi
    continue
  fi

  # Ensure issue labels reflect status only when task changed
  if [ "$UPDATED_AT" = "$GH_SYNCED_AT" ]; then
    if [ -n "$GH_NUM" ] && [ "$GH_NUM" != "null" ] && [ "$STATUS" != "$GH_SYNCED_STATUS" ]; then
      sync_project_status "$GH_NUM" "$STATUS"
      db_task_update "$ID" "gh_synced_status=$STATUS"
    fi
    continue
  fi

  log "[gh_push] [$PROJECT_NAME] task=$ID syncing (updated_at=$UPDATED_AT gh_synced_at=$GH_SYNCED_AT)"

  LABEL_ARGS=()
  for lbl in $(printf '%s' "$LABELS_FOR_GH" | jq -r '.[]'); do
    LABEL_ARGS+=("-f" "labels[]=$lbl")
  done
  gh_api "repos/$REPO/issues/$GH_NUM" -X PATCH "${LABEL_ARGS[@]}" >/dev/null

  # Add/remove red "blocked" label based on status
  if [ "$STATUS" = "blocked" ] || [ "$STATUS" = "needs_review" ]; then
    ensure_label "blocked" "d73a4a" "Task is blocked and needs attention"
    gh_api "repos/$REPO/issues/$GH_NUM/labels" \
      --input - <<< '{"labels":["blocked"]}' >/dev/null 2>&1 || true
  else
    gh_api "repos/$REPO/issues/$GH_NUM/labels/blocked" -X DELETE >/dev/null 2>&1 || true
  fi

  # Add agent label
  if [ -n "$AGENT" ] && [ "$AGENT" != "null" ]; then
    AGENT_LABEL="agent:${AGENT}"
    ensure_label "$AGENT_LABEL" "c5def5" "Assigned to $AGENT agent"
    gh_api "repos/$REPO/issues/$GH_NUM/labels" \
      --input - <<< "{\"labels\":[\"$AGENT_LABEL\"]}" >/dev/null 2>&1 || true
  fi

  # Subscribe owner to issue notifications
  gh_api "repos/$REPO/issues/$GH_NUM/subscription" \
    -X PUT --input - <<< '{"subscribed":true,"ignored":false}' >/dev/null 2>&1 || true

  # Post a comment for the update
  if [ -n "$UPDATED_AT" ]; then
    BADGE=$(agent_badge "$AGENT")
    IS_BLOCKED=false
    if [ "$STATUS" = "blocked" ] || [ "$STATUS" = "needs_review" ]; then
      IS_BLOCKED=true
    fi

    if [ "$IS_BLOCKED" = true ] || { [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; }; then

      COMMENT=""

      if [ "$IS_BLOCKED" = true ]; then
        COMMENT="## ${BADGE} Needs Help"
      elif [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
        COMMENT="## ${BADGE} ${SUMMARY}"
      fi

      COMMENT="${COMMENT}

| | |
|---|---|
| **Status** | \`${STATUS}\` |
| **Agent** | ${AGENT:-unknown} |"
      if [ -n "$AGENT_MODEL_VAL" ] && [ "$AGENT_MODEL_VAL" != "null" ]; then
        COMMENT="${COMMENT}
| **Model** | \`${AGENT_MODEL_VAL}\` |"
      fi
      COMMENT="${COMMENT}
| **Attempt** | ${ATTEMPTS_VAL} |"
      if [ "$DURATION" -gt 0 ] 2>/dev/null; then
        DURATION_FMT=$(duration_fmt "$DURATION")
        COMMENT="${COMMENT}
| **Duration** | ${DURATION_FMT} |"
      fi
      if [ "$INPUT_TOKENS" -gt 0 ] 2>/dev/null; then
        if [ "$INPUT_TOKENS" -ge 1000 ]; then
          IN_FMT="$((INPUT_TOKENS / 1000))k"
        else
          IN_FMT="$INPUT_TOKENS"
        fi
        if [ "$OUTPUT_TOKENS" -ge 1000 ]; then
          OUT_FMT="$((OUTPUT_TOKENS / 1000))k"
        else
          OUT_FMT="$OUTPUT_TOKENS"
        fi
        COMMENT="${COMMENT}
| **Tokens** | ${IN_FMT} in / ${OUT_FMT} out |"
      fi
      if [ -n "$PROMPT_HASH" ] && [ "$PROMPT_HASH" != "null" ]; then
        COMMENT="${COMMENT}
| **Prompt** | \`${PROMPT_HASH}\` |"
      fi

      if [ "$IS_BLOCKED" = true ] && [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
        COMMENT="${COMMENT}

${SUMMARY}"
      fi

      if [ -n "$REASON" ] && [ "$REASON" != "null" ] || \
         [ -n "$LAST_ERROR" ] && [ "$LAST_ERROR" != "null" ] || \
         [ -n "$BLOCKERS_LIST" ]; then
        COMMENT="${COMMENT}

### Errors & Blockers"
        if [ -n "$REASON" ] && [ "$REASON" != "null" ]; then
          COMMENT="${COMMENT}

**Reason:** ${REASON}"
        fi
        if [ -n "$LAST_ERROR" ] && [ "$LAST_ERROR" != "null" ]; then
          COMMENT="${COMMENT}

> \`${LAST_ERROR}\`"
        fi
        if [ -n "$BLOCKERS_LIST" ]; then
          COMMENT="${COMMENT}

${BLOCKERS_LIST}"
        fi
      fi

      if [ -n "$ACCOMPLISHED_LIST" ]; then
        COMMENT="${COMMENT}

### Accomplished

${ACCOMPLISHED_LIST}"
      fi

      if [ -n "$REMAINING_LIST" ]; then
        COMMENT="${COMMENT}

### Remaining

${REMAINING_LIST}"
      fi

      if [ -n "$FILES_CHANGED_LIST" ]; then
        COMMENT="${COMMENT}

### Files Changed

${FILES_CHANGED_LIST}"
      fi

      if [ "$IS_BLOCKED" = true ]; then
        COMMENT="${COMMENT}

> ⚠️ This task needs your attention."
      fi

      TOOL_ACTIVITY=$(read_tool_summary "$TASK_DIR_VAL" "$ID")
      if [ -n "$TOOL_ACTIVITY" ]; then
        COMMENT="${COMMENT}

### Agent Activity

${TOOL_ACTIVITY}"
      fi

      if [ -n "$STDERR_SNIPPET" ] && [ "$STDERR_SNIPPET" != "null" ]; then
        COMMENT="${COMMENT}

<details><summary>Agent stderr</summary>

\`\`\`
${STDERR_SNIPPET}
\`\`\`

</details>"
      fi

      PROMPT_CONTENT=$(read_prompt_file "$TASK_DIR_VAL" "$ID")
      if [ -n "$PROMPT_CONTENT" ]; then
        COMMENT="${COMMENT}

<details><summary>Prompt sent to agent</summary>

\`\`\`
${PROMPT_CONTENT}
\`\`\`

</details>"
      fi

      AGENT_NAME="${AGENT:-orchestrator}"
      MODEL_SUFFIX=""
      if [ -n "$AGENT_MODEL_VAL" ] && [ "$AGENT_MODEL_VAL" != "null" ]; then
        MODEL_SUFFIX=" using model \`${AGENT_MODEL_VAL}\`"
      fi
      COMMENT="${COMMENT}

---
*By ${AGENT_NAME}[bot]${MODEL_SUFFIX} via [Orchestrator](https://github.com/gabrielkoerich/orchestrator)*"

      if ! db_should_skip_comment "$ID" "$COMMENT"; then
        gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="$COMMENT" >/dev/null
        db_store_comment_hash "$ID" "$COMMENT"
        log "[gh_push] [$PROJECT_NAME] task=$ID posted comment on #$GH_NUM (status=$STATUS prompt=$PROMPT_HASH)"
      else
        log "[gh_push] [$PROJECT_NAME] task=$ID skipped duplicate comment on #$GH_NUM"
      fi
    fi
  fi

  db_task_set_synced "$ID" "$STATUS"
  log "[gh_push] [$PROJECT_NAME] task=$ID synced"

  if [ "$STATUS" != "$GH_SYNCED_STATUS" ]; then
    sync_project_status "$GH_NUM" "$STATUS"
    db_task_update "$ID" "gh_synced_status=$STATUS"
  fi

done <<< "$ALL_IDS"

# --- Catch-all: create PRs for pushed branches that don't have one ---
while IFS=$'\x1f' read -r _ID _BRANCH _STATUS _TITLE _SUMMARY _WORKTREE _AGENT _GH_NUM; do
  [ -n "$_ID" ] || continue

  # Check if branch exists on remote
  if ! git ls-remote --heads origin "$_BRANCH" 2>/dev/null | grep -q "$_BRANCH"; then
    continue
  fi

  # Check if PR already exists
  EXISTING_PR=$(gh pr list --repo "$REPO" --head "$_BRANCH" --json number -q '.[0].number' 2>/dev/null || true)
  if [ -n "$EXISTING_PR" ]; then
    continue
  fi

  # Check if branch has commits beyond main
  HAS_COMMITS=false
  if [ -n "$_WORKTREE" ] && [ -d "$_WORKTREE" ]; then
    if (cd "$_WORKTREE" && git log "origin/main..HEAD" --oneline 2>/dev/null | grep -q .); then
      HAS_COMMITS=true
    fi
  else
    if git log "origin/main..origin/$_BRANCH" --oneline 2>/dev/null | grep -q .; then
      HAS_COMMITS=true
    fi
  fi
  [ "$HAS_COMMITS" = true ] || continue

  PR_TITLE="${_SUMMARY:-$_TITLE}"
  PR_BODY="## Summary

${_SUMMARY:-$_TITLE}

${_GH_NUM:+Closes #${_GH_NUM}}

---
*Created by ${_AGENT:-orchestrator}[bot] via [Orchestrator](https://github.com/gabrielkoerich/orchestrator)*"

  PR_URL=$(gh pr create --repo "$REPO" --title "$PR_TITLE" --body "$PR_BODY" --head "$_BRANCH" 2>/dev/null || true)
  if [ -n "$PR_URL" ]; then
    log "[gh_push] [$PROJECT_NAME] task=$_ID created catch-all PR for branch $_BRANCH: $PR_URL"
  fi
done < <(db_tasks_with_branches)
