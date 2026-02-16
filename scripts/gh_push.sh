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
# Returns markdown: table of tool counts + collapsed error details
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
    log "[gh_push] added issue #$issue_number to project"
  fi

  gh_api graphql -f query='mutation($project:ID!, $item:ID!, $field:ID!, $option:String!){ updateProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field, value:{singleSelectOptionId:$option}}){ projectV2Item{id} } }' \
    -f project="$PROJECT_ID" -f item="$item_id" -f field="$PROJECT_STATUS_FIELD_ID" -f option="$option_id" >/dev/null
}

# Content-hash dedup: hash comment body, compare with stored last_comment_hash.
# Returns 0 (skip) if hash matches, 1 (post) if new. Stores hash after caller posts.
should_skip_comment() {
  local task_id="$1" body="$2"
  local new_hash
  new_hash=$(printf '%s' "$body" | shasum -a 256 | cut -c1-16)
  local old_hash
  old_hash=$(yq -r ".tasks[] | select(.id == $task_id) | .last_comment_hash // \"\"" "$TASKS_PATH")
  if [ "$new_hash" = "$old_hash" ]; then
    return 0  # skip
  fi
  return 1  # post
}

store_comment_hash() {
  local task_id="$1" body="$2"
  local hash
  hash=$(printf '%s' "$body" | shasum -a 256 | cut -c1-16)
  export hash
  with_lock yq -i \
    "(.tasks[] | select(.id == $task_id) | .last_comment_hash) = strenv(hash)" \
    "$TASKS_PATH"
}

# Ensure a label exists on the repo (create with color if missing).
# Usage: ensure_label "blocked" "d73a4a" "Task is blocked and needs attention"
ensure_label() {
  local name="$1" color="${2:-ededed}" description="${3:-}"
  # Try to get the label; create it if 404
  if ! gh_api "repos/$REPO/labels/$(printf '%s' "$name" | jq -sRr @uri)" >/dev/null 2>&1; then
    gh_api "repos/$REPO/labels" \
      -f name="$name" -f color="$color" -f description="$description" >/dev/null 2>&1 || true
  fi
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
  ACCOMPLISHED_LIST=$(yq -r ".tasks[$i].accomplished // [] | .[] | \"- \" + ." "$TASKS_PATH")
  REMAINING=$(yq -r ".tasks[$i].remaining // [] | join(\", \" )" "$TASKS_PATH")
  REMAINING_LIST=$(yq -r ".tasks[$i].remaining // [] | .[] | \"- \" + ." "$TASKS_PATH")
  BLOCKERS=$(yq -r ".tasks[$i].blockers // [] | join(\", \" )" "$TASKS_PATH")
  BLOCKERS_LIST=$(yq -r ".tasks[$i].blockers // [] | .[] | \"- \" + ." "$TASKS_PATH")
  FILES_CHANGED_JSON=$(yq -o=json -I=0 ".tasks[$i].files_changed // []" "$TASKS_PATH")
  FILES_CHANGED_LIST=$(yq -r ".tasks[$i].files_changed // [] | .[] | \"- \\\`\" + . + \"\\\`\"" "$TASKS_PATH")
  LAST_ERROR=$(yq -r ".tasks[$i].last_error // \"\"" "$TASKS_PATH")
  AGENT=$(yq -r ".tasks[$i].agent // \"\"" "$TASKS_PATH")
  AGENT_MODEL=$(yq -r ".tasks[$i].agent_model // \"\"" "$TASKS_PATH")
  PROMPT_HASH=$(yq -r ".tasks[$i].prompt_hash // \"\"" "$TASKS_PATH")
  TASK_DIR=$(yq -r ".tasks[$i].dir // \"\"" "$TASKS_PATH")
  ATTEMPTS=$(yq -r ".tasks[$i].attempts // 0" "$TASKS_PATH")
  DURATION=$(yq -r ".tasks[$i].duration // 0" "$TASKS_PATH")
  INPUT_TOKENS=$(yq -r ".tasks[$i].input_tokens // 0" "$TASKS_PATH")
  OUTPUT_TOKENS=$(yq -r ".tasks[$i].output_tokens // 0" "$TASKS_PATH")
  STDERR_SNIPPET=$(yq -r ".tasks[$i].stderr_snippet // \"\"" "$TASKS_PATH")
  UPDATED_AT=$(yq -r ".tasks[$i].updated_at // \"\"" "$TASKS_PATH")
  GH_SYNCED_AT=$(yq -r ".tasks[$i].gh_synced_at // \"\"" "$TASKS_PATH")

  log "[gh_push] task id=$ID status=$STATUS title=$(printf '%s' "$TITLE" | head -c 80)"

  skip=false
  for lbl in "${SKIP_LABELS[@]}"; do
    idx=$(printf '%s' "$LABELS_JSON" | yq -r "index(\"$lbl\")" 2>/dev/null || true)
    if [ -n "$idx" ] && [ "$idx" != "null" ]; then
      skip=true
      break
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
      log_err "Skipping task $ID: missing title; cannot create GitHub issue." >&2
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

    export NUM URL STATE
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_issue_number) = (env(NUM) | tonumber) | \
       (.tasks[] | select(.id == $ID) | .gh_url) = strenv(URL) | \
       (.tasks[] | select(.id == $ID) | .gh_state) = strenv(STATE) | \
       (.tasks[] | select(.id == $ID)).gh_synced_at = (.tasks[] | select(.id == $ID)).updated_at" \
      "$TASKS_PATH"

    log "[gh_push] task=$ID created issue #$NUM"
    sync_project_status "$NUM" "$STATUS"
    continue
  fi

  # Ensure issue labels reflect status only when task changed
  if [ "$UPDATED_AT" = "$GH_SYNCED_AT" ]; then
    continue
  fi

  log "[gh_push] task=$ID syncing (updated_at=$UPDATED_AT gh_synced_at=$GH_SYNCED_AT)"

  LABEL_ARGS=()
  LABEL_COUNT=$(printf '%s' "$LABELS_FOR_GH" | yq -r 'length')
  for j in $(seq 0 $((LABEL_COUNT - 1))); do
    LBL=$(printf '%s' "$LABELS_FOR_GH" | yq -r ".[$j]")
    LABEL_ARGS+=("-f" "labels[]=$LBL")
  done
  gh_api "repos/$REPO/issues/$GH_NUM" -X PATCH "${LABEL_ARGS[@]}" >/dev/null

  # Add/remove red "blocked" label based on status
  if [ "$STATUS" = "blocked" ] || [ "$STATUS" = "needs_review" ]; then
    ensure_label "blocked" "d73a4a" "Task is blocked and needs attention"
    gh_api "repos/$REPO/issues/$GH_NUM/labels" \
      --input - <<< '{"labels":["blocked"]}' >/dev/null 2>&1 || true
  else
    # Remove blocked label if present (ignore 404)
    gh_api "repos/$REPO/issues/$GH_NUM/labels/blocked" -X DELETE >/dev/null 2>&1 || true
  fi

  # Add agent label (agent:claude, agent:codex, agent:opencode)
  if [ -n "$AGENT" ] && [ "$AGENT" != "null" ]; then
    AGENT_LABEL="agent:${AGENT}"
    ensure_label "$AGENT_LABEL" "c5def5" "Assigned to $AGENT agent"
    gh_api "repos/$REPO/issues/$GH_NUM/labels" \
      --input - <<< "{\"labels\":[\"$AGENT_LABEL\"]}" >/dev/null 2>&1 || true
  fi

  # Post a comment for the update (we already know task changed from the gate above)
  if [ -n "$UPDATED_AT" ]; then
    OWNER_TAG="@$(repo_owner "$REPO")"
    BADGE=$(agent_badge "$AGENT")
    IS_BLOCKED=false
    if [ "$STATUS" = "blocked" ] || [ "$STATUS" = "needs_review" ]; then
      IS_BLOCKED=true
    fi

    # Only post if there's something meaningful to say
    if [ "$IS_BLOCKED" = true ] || { [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; }; then

      # --- Build comment ---
      COMMENT=""

      # Header: summary as title (or "Needs help" for blocked)
      if [ "$IS_BLOCKED" = true ]; then
        COMMENT="## ${BADGE} Needs Help"
      elif [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
        COMMENT="## ${BADGE} ${SUMMARY}"
      fi

      # Status & metadata table
      COMMENT="${COMMENT}

| | |
|---|---|
| **Status** | \`${STATUS}\` |
| **Agent** | ${AGENT:-unknown} |"
      if [ -n "$AGENT_MODEL" ] && [ "$AGENT_MODEL" != "null" ]; then
        COMMENT="${COMMENT}
| **Model** | \`${AGENT_MODEL}\` |"
      fi
      COMMENT="${COMMENT}
| **Attempt** | ${ATTEMPTS} |"
      if [ "$DURATION" -gt 0 ] 2>/dev/null; then
        DURATION_FMT=$(duration_fmt "$DURATION")
        COMMENT="${COMMENT}
| **Duration** | ${DURATION_FMT} |"
      fi
      if [ "$INPUT_TOKENS" -gt 0 ] 2>/dev/null; then
        # Format tokens as "15k in / 3k out"
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

      # Summary paragraph (only when blocked, since progress uses it as the title)
      if [ "$IS_BLOCKED" = true ] && [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
        COMMENT="${COMMENT}

${SUMMARY}"
      fi

      # Reason / error section
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

      # Accomplished
      if [ -n "$ACCOMPLISHED_LIST" ]; then
        COMMENT="${COMMENT}

### Accomplished

${ACCOMPLISHED_LIST}"
      fi

      # Remaining
      if [ -n "$REMAINING_LIST" ]; then
        COMMENT="${COMMENT}

### Remaining

${REMAINING_LIST}"
      fi

      # Files changed
      if [ -n "$FILES_CHANGED_LIST" ]; then
        COMMENT="${COMMENT}

### Files Changed

${FILES_CHANGED_LIST}"
      fi

      # Owner ping for blocked tasks
      if [ "$IS_BLOCKED" = true ]; then
        COMMENT="${COMMENT}

---
${OWNER_TAG} this task needs your attention."
      fi

      # Tool activity
      TOOL_ACTIVITY=$(read_tool_summary "$TASK_DIR" "$ID")
      if [ -n "$TOOL_ACTIVITY" ]; then
        COMMENT="${COMMENT}

### Agent Activity

${TOOL_ACTIVITY}"
      fi

      # Collapsed stderr
      if [ -n "$STDERR_SNIPPET" ] && [ "$STDERR_SNIPPET" != "null" ]; then
        COMMENT="${COMMENT}

<details><summary>Agent stderr</summary>

\`\`\`
${STDERR_SNIPPET}
\`\`\`

</details>"
      fi

      # Collapsed prompt
      PROMPT_CONTENT=$(read_prompt_file "$TASK_DIR" "$ID")
      if [ -n "$PROMPT_CONTENT" ]; then
        COMMENT="${COMMENT}

<details><summary>Prompt sent to agent</summary>

\`\`\`
${PROMPT_CONTENT}
\`\`\`

</details>"
      fi

      # --- Post with dedup ---
      if ! should_skip_comment "$ID" "$COMMENT"; then
        gh_api "repos/$REPO/issues/$GH_NUM/comments" -f body="$COMMENT" >/dev/null
        store_comment_hash "$ID" "$COMMENT"
        log "[gh_push] task=$ID posted comment on #$GH_NUM (status=$STATUS prompt=$PROMPT_HASH)"
      else
        log "[gh_push] task=$ID skipped duplicate comment on #$GH_NUM"
      fi
    fi
  fi

  # Mark synced atomically — copy the task's own updated_at so we never use a stale shell var
  with_lock yq -i \
    "(.tasks[] | select(.id == $ID)).gh_synced_at = (.tasks[] | select(.id == $ID)).updated_at" \
    "$TASKS_PATH"
  log "[gh_push] task=$ID synced"

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
    with_lock yq -i \
      "(.tasks[] | select(.id == $ID) | .gh_state) = \"closed\"" \
      "$TASKS_PATH"
  fi

  sync_project_status "$GH_NUM" "$STATUS"

done
