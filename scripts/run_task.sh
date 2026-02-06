#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
require_jq
init_config_file

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    TASK_ID=$(yq -r '.tasks[] | select(.status == "routed") | .id' "$TASKS_PATH" | head -n1)
  fi
  if [ -z "$TASK_ID" ]; then
    NOW_EPOCH=$(now_epoch)
    TASK_ID=$(yq -r ".tasks[] | select(.status == \"needs_review\" and (.retry_at == null or .retry_at <= $NOW_EPOCH)) | .id" "$TASKS_PATH" | head -n1)
  fi
  if [ -z "$TASK_ID" ]; then
    echo "No runnable tasks found" >&2
    exit 1
  fi
fi

echo "[run] task=$TASK_ID starting" >&2
export TASK_ID

# Per-task lock to avoid double-run across multiple watchers
TASK_LOCK="${LOCK_PATH}.task.${TASK_ID}"
if ! mkdir "$TASK_LOCK" 2>/dev/null; then
  lock_pid=""
  if [ -f "$TASK_LOCK/pid" ]; then
    lock_pid=$(cat "$TASK_LOCK/pid" 2>/dev/null || true)
  fi
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" >/dev/null 2>&1; then
    echo "Task $TASK_ID already running" >&2
    exit 0
  fi
  if lock_is_stale "$TASK_LOCK"; then
    rmdir "$TASK_LOCK" 2>/dev/null || true
  fi
  if ! mkdir "$TASK_LOCK" 2>/dev/null; then
    echo "Task $TASK_ID already running" >&2
    exit 0
  fi
fi
echo "$$" > "$TASK_LOCK/pid"
trap 'rm -f "$TASK_LOCK/pid"; rmdir "$TASK_LOCK" 2>/dev/null || true' EXIT

TASK_TITLE=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .title' "$TASKS_PATH")
TASK_BODY=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .body' "$TASKS_PATH")
TASK_LABELS=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .labels | join(",")' "$TASKS_PATH")
TASK_AGENT=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .agent' "$TASKS_PATH")
AGENT_MODEL=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .agent_model // ""' "$TASKS_PATH")
AGENT_PROFILE_JSON=$(yq -o=json -I=0 '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .agent_profile // {}' "$TASKS_PATH")
ATTEMPTS=$(yq -r '.tasks[] | select(.id == (env(TASK_ID) | tonumber)) | .attempts // 0' "$TASKS_PATH")
ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | yq -r '.role // "general"')

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  TASK_TITLE=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .title" "$TASKS_PATH")
  TASK_BODY=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .body" "$TASKS_PATH")
  TASK_LABELS=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .labels | join(\",\")" "$TASKS_PATH")
  TASK_AGENT=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .agent" "$TASKS_PATH")
  AGENT_MODEL=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .agent_model // \"\"" "$TASKS_PATH")
  AGENT_PROFILE_JSON=$(yq -o=json -I=0 ".tasks[] | select(.id == \"$TASK_ID\") | .agent_profile // {}" "$TASKS_PATH")
  ATTEMPTS=$(yq -r ".tasks[] | select(.id == \"$TASK_ID\") | .attempts // 0" "$TASKS_PATH")
  ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | yq -r '.role // "general"')
fi

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  TASK_JSON=$(yq -o=json -I=0 '.' "$TASKS_PATH")
  TASK_TITLE=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | .title")
  TASK_BODY=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | .body")
  TASK_LABELS=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | (.labels // []) | join(\",\")")
  TASK_AGENT=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | .agent")
  AGENT_MODEL=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | .agent_model // \"\"")
  AGENT_PROFILE_JSON=$(printf '%s' "$TASK_JSON" | jq -c ".tasks[] | select(.id == $TASK_ID) | .agent_profile // {}")
  ATTEMPTS=$(printf '%s' "$TASK_JSON" | jq -r ".tasks[] | select(.id == $TASK_ID) | .attempts // 0")
  ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | jq -r '.role // "general"')
fi
CLAUDE_INPUT_FORMAT=$(config_get '.llm.input_format // ""')
CLAUDE_OUTPUT_FORMAT=$(config_get '.llm.output_format // ""')

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  echo "Task $TASK_ID not found" >&2
  exit 1
fi

if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
  TASK_AGENT=$("$(dirname "$0")/route_task.sh" "$TASK_ID")
  TASK_AGENT=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .agent" "$TASKS_PATH")
  AGENT_PROFILE_JSON=$(yq -o=json -I=0 ".tasks[] | select(.id == $TASK_ID) | .agent_profile // {}" "$TASKS_PATH")
  AGENT_MODEL=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .agent_model // \"\"" "$TASKS_PATH")
  ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | yq -r '.role // "general"')
fi

if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
  echo "[run] task=$TASK_ID missing agent after routing" >&2
  NOW_EPOCH=$(now_epoch)
  DELAY=$(retry_delay_seconds "$ATTEMPTS")
  RETRY_AT=$((NOW_EPOCH + DELAY))
  NOW=$(now_iso)
  export NOW RETRY_AT
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"router did not set agent\" | \
     (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "needs_review" "router did not set agent"
  exit 0
fi

TASK_CONTEXT=$(load_task_context "$TASK_ID" "$ROLE")

ATTEMPTS=$((ATTEMPTS + 1))
NOW=$(now_iso)
export NOW ATTEMPTS

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = \"in_progress\" | \
   (.tasks[] | select(.id == $TASK_ID) | .attempts) = (env(ATTEMPTS) | tonumber) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

append_history "$TASK_ID" "in_progress" "started attempt $ATTEMPTS"

PROMPT=$(render_template "prompts/agent.md" "$TASK_ID" "$TASK_TITLE" "$TASK_LABELS" "$TASK_BODY" "$AGENT_PROFILE_JSON" "" "" "$TASK_CONTEXT")

RESPONSE=""
CMD_STATUS=0
case "$TASK_AGENT" in
  codex)
    echo "[run] using codex model=${AGENT_MODEL:-default}" >&2
    if [ -n "$AGENT_MODEL" ]; then
      RESPONSE=$(run_with_timeout codex exec --model "$AGENT_MODEL" --json "$PROMPT") || CMD_STATUS=$?
    else
      RESPONSE=$(run_with_timeout codex exec --json "$PROMPT") || CMD_STATUS=$?
    fi
    ;;
  claude)
    echo "[run] using claude model=${AGENT_MODEL:-default}" >&2
    if [ -n "$AGENT_MODEL" ]; then
      if [ -n "$CLAUDE_INPUT_FORMAT" ] || [ -n "$CLAUDE_OUTPUT_FORMAT" ]; then
        RESPONSE=$(run_with_timeout claude --model "$AGENT_MODEL" ${CLAUDE_INPUT_FORMAT:+--input-format "$CLAUDE_INPUT_FORMAT"} ${CLAUDE_OUTPUT_FORMAT:+--output-format "$CLAUDE_OUTPUT_FORMAT"} --print "$PROMPT") || CMD_STATUS=$?
      else
        RESPONSE=$(run_with_timeout claude --model "$AGENT_MODEL" --print "$PROMPT") || CMD_STATUS=$?
      fi
    else
      if [ -n "$CLAUDE_INPUT_FORMAT" ] || [ -n "$CLAUDE_OUTPUT_FORMAT" ]; then
        RESPONSE=$(run_with_timeout claude ${CLAUDE_INPUT_FORMAT:+--input-format "$CLAUDE_INPUT_FORMAT"} ${CLAUDE_OUTPUT_FORMAT:+--output-format "$CLAUDE_OUTPUT_FORMAT"} --print "$PROMPT") || CMD_STATUS=$?
      else
        RESPONSE=$(run_with_timeout claude --print "$PROMPT") || CMD_STATUS=$?
      fi
    fi
    ;;
  opencode)
    echo "[run] using opencode" >&2
    RESPONSE=$(run_with_timeout opencode run --format json "$PROMPT") || CMD_STATUS=$?
    ;;
  *)
    echo "Unknown agent: $TASK_AGENT" >&2
    exit 1
    ;;
esac

echo "[run] raw response:" >&2
printf '%s\n' "$RESPONSE" | sed 's/^/[run] > /' >&2

if [ "$CMD_STATUS" -ne 0 ]; then
  echo "[run] task=$TASK_ID agent command failed exit=$CMD_STATUS" >&2
  NOW_EPOCH=$(now_epoch)
  DELAY=$(retry_delay_seconds "$ATTEMPTS")
  RETRY_AT=$((NOW_EPOCH + DELAY))
  NOW=$(now_iso)
  export NOW RETRY_AT
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"agent command failed (exit $CMD_STATUS)\" | \
     (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "needs_review" "agent command failed (exit $CMD_STATUS)"
  exit 0
fi

RESPONSE_JSON=$(normalize_json_response "$RESPONSE" 2>/dev/null || true)
if [ -z "$RESPONSE_JSON" ]; then
  echo "[run] task=$TASK_ID invalid JSON response" >&2
  NOW_EPOCH=$(now_epoch)
  DELAY=$(retry_delay_seconds "$ATTEMPTS")
  RETRY_AT=$((NOW_EPOCH + DELAY))
  NOW=$(now_iso)
  export NOW RETRY_AT
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"agent response invalid YAML/JSON\" | \
     (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"
  mkdir -p "$CONTEXTS_DIR"
  printf '%s' "$RESPONSE" > "${CONTEXTS_DIR}/response-${TASK_ID}.md"
  append_history "$TASK_ID" "needs_review" "agent response invalid YAML/JSON"
  exit 0
fi

AGENT_STATUS=$(printf '%s' "$RESPONSE_JSON" | jq -r '.status // ""')
SUMMARY=$(printf '%s' "$RESPONSE_JSON" | jq -r '.summary // ""')
ACCOMPLISHED_STR=$(printf '%s' "$RESPONSE_JSON" | jq -r '.accomplished[]?' | tr '\n' '\n')
REMAINING_STR=$(printf '%s' "$RESPONSE_JSON" | jq -r '.remaining[]?' | tr '\n' '\n')
BLOCKERS_STR=$(printf '%s' "$RESPONSE_JSON" | jq -r '.blockers[]?' | tr '\n' '\n')
FILES_CHANGED_STR=$(printf '%s' "$RESPONSE_JSON" | jq -r '.files_changed[]?' | tr '\n' '\n')
REMAINING_STR=${REMAINING_STR:-""}
ACCOMPLISHED_STR=${ACCOMPLISHED_STR:-""}
BLOCKERS_STR=${BLOCKERS_STR:-""}
FILES_CHANGED_STR=${FILES_CHANGED_STR:-""}
NEEDS_HELP=$(printf '%s' "$RESPONSE_JSON" | jq -r '.needs_help // false')
DELEGATIONS_JSON=$(printf '%s' "$RESPONSE_JSON" | jq -c '.delegations // []')

if [ -z "$AGENT_STATUS" ] || [ "$AGENT_STATUS" = "null" ]; then
  NOW_EPOCH=$(now_epoch)
  DELAY=$(retry_delay_seconds "$ATTEMPTS")
  RETRY_AT=$((NOW_EPOCH + DELAY))
  NOW=$(now_iso)
  export NOW RETRY_AT
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"agent response missing status\" | \
     (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "needs_review" "agent response missing status"
  exit 0
fi

NOW=$(now_iso)
export AGENT_STATUS SUMMARY NEEDS_HELP NOW FILES_CHANGED_STR ACCOMPLISHED_STR REMAINING_STR BLOCKERS_STR

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = strenv(AGENT_STATUS) | \
   (.tasks[] | select(.id == $TASK_ID) | .summary) = strenv(SUMMARY) | \
   (.tasks[] | select(.id == $TASK_ID) | .accomplished) = (strenv(ACCOMPLISHED_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .remaining) = (strenv(REMAINING_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .blockers) = (strenv(BLOCKERS_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .files_changed) = (strenv(FILES_CHANGED_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .needs_help) = (strenv(NEEDS_HELP) == \"true\") | \
   (.tasks[] | select(.id == $TASK_ID) | .last_error) = null | \
   (.tasks[] | select(.id == $TASK_ID) | .retry_at) = null | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

append_history "$TASK_ID" "$AGENT_STATUS" "agent completed"

FILES_CHANGED=$(printf '%s' "$RESPONSE_JSON" | jq -r '.files_changed | join(", ")')
append_task_context "$TASK_ID" "[$NOW] status: $AGENT_STATUS\nsummary: $SUMMARY\nfiles: $FILES_CHANGED\n"

# Optional review step
ENABLE_REVIEW_AGENT=${ENABLE_REVIEW_AGENT:-$(config_get '.workflow.enable_review_agent // false')}
REVIEW_AGENT=${REVIEW_AGENT:-$(config_get '.workflow.review_agent // "claude"')}

if [ "$AGENT_STATUS" = "done" ] && [ "$ENABLE_REVIEW_AGENT" = "true" ]; then
  FILES_CHANGED=$(printf '%s' "$RESPONSE" | yq -r '.files_changed | join(", ")')
  REVIEW_PROMPT=$(render_template "prompts/review.md" "$TASK_ID" "$TASK_TITLE" "$TASK_LABELS" "$TASK_BODY" "{}" "$SUMMARY" "$FILES_CHANGED" "")

  REVIEW_RESPONSE=""
  REVIEW_STATUS=0
  case "$REVIEW_AGENT" in
    codex)
      REVIEW_RESPONSE=$(run_with_timeout codex --print "$REVIEW_PROMPT") || REVIEW_STATUS=$?
      ;;
    claude)
      REVIEW_RESPONSE=$(run_with_timeout claude --print "$REVIEW_PROMPT") || REVIEW_STATUS=$?
      ;;
    *)
      echo "Unknown review agent: $REVIEW_AGENT" >&2
      REVIEW_STATUS=1
      ;;
  esac

  if [ "$REVIEW_STATUS" -ne 0 ]; then
    NOW_EPOCH=$(now_epoch)
    DELAY=$(retry_delay_seconds "$ATTEMPTS")
    RETRY_AT=$((NOW_EPOCH + DELAY))
    NOW=$(now_iso)
    export NOW RETRY_AT
    with_lock yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
       (.tasks[] | select(.id == $TASK_ID) | .review_decision) = \"request_changes\" | \
       (.tasks[] | select(.id == $TASK_ID) | .review_notes) = \"review agent failed\" | \
       (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"review agent failed\" | \
       (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
       (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
      "$TASKS_PATH"
    append_history "$TASK_ID" "needs_review" "review agent failed"
    exit 0
  fi

  REVIEW_DECISION=$(printf '%s' "$REVIEW_RESPONSE" | yq -r '.decision // ""')
  REVIEW_NOTES=$(printf '%s' "$REVIEW_RESPONSE" | yq -r '.notes // ""')

  if [ "$REVIEW_DECISION" = "request_changes" ]; then
    NOW_EPOCH=$(now_epoch)
    DELAY=$(retry_delay_seconds "$ATTEMPTS")
    RETRY_AT=$((NOW_EPOCH + DELAY))
    NOW=$(now_iso)
    export NOW RETRY_AT REVIEW_NOTES
    with_lock yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
       (.tasks[] | select(.id == $TASK_ID) | .review_decision) = \"request_changes\" | \
       (.tasks[] | select(.id == $TASK_ID) | .review_notes) = env(REVIEW_NOTES) | \
       (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"review requested changes\" | \
       (.tasks[] | select(.id == $TASK_ID) | .retry_at) = (env(RETRY_AT) | tonumber) | \
       (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
      "$TASKS_PATH"
    append_history "$TASK_ID" "needs_review" "review requested changes"
    exit 0
  fi

  NOW=$(now_iso)
  export NOW REVIEW_NOTES
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .review_decision) = \"approve\" | \
     (.tasks[] | select(.id == $TASK_ID) | .review_notes) = env(REVIEW_NOTES) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "done" "review approved"
fi

DELEG_COUNT=$(printf '%s' "$DELEGATIONS_JSON" | jq -r 'length')

if [ "$DELEG_COUNT" -gt 0 ]; then
  acquire_lock

  MAX_ID=$(yq -r '(.tasks | map(.id) | max) // 0' "$TASKS_PATH")
  CHILD_IDS=()
  for i in $(seq 0 $((DELEG_COUNT - 1))); do
    TITLE=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].title // \"\"")
    BODY=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].body // \"\"")
    LABELS_CSV=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].labels // [] | join(\",\")")
    SUGGESTED_AGENT=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].suggested_agent // \"\"")

    MAX_ID=$((MAX_ID + 1))
    NOW=$(now_iso)
    export MAX_ID TITLE BODY LABELS_CSV SUGGESTED_AGENT NOW

    yq -i \
      '.tasks += [{
        "id": (env(MAX_ID) | tonumber),
        "title": strenv(TITLE),
        "body": strenv(BODY),
        "labels": (strenv(LABELS_CSV) | split(",") | map(select(length > 0))),
        "status": "new",
        "agent": (strenv(SUGGESTED_AGENT) | select(length > 0) // null),
        "agent_model": null,
        "agent_profile": null,
        "selected_skills": [],
        "parent_id": (env(TASK_ID) | tonumber),
        "children": [],
        "route_reason": null,
        "route_warning": null,
        "summary": null,
        "accomplished": [],
        "remaining": [],
        "blockers": [],
        "files_changed": [],
        "needs_help": false,
        "attempts": 0,
        "last_error": null,
        "retry_at": null,
        "review_decision": null,
        "review_notes": null,
        "history": [],
        "created_at": env(NOW),
        "updated_at": env(NOW)
      }]' \
      "$TASKS_PATH"

    yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .children) += [$MAX_ID]" \
      "$TASKS_PATH"

    CHILD_IDS+=("$MAX_ID")
  done

  NOW=$(now_iso)
  export NOW
  yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"blocked\" | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
    "$TASKS_PATH"

  release_lock

  printf 'Spawned children: %s\n' "${CHILD_IDS[*]}"
  append_history "$TASK_ID" "blocked" "spawned children: ${CHILD_IDS[*]}"
fi
