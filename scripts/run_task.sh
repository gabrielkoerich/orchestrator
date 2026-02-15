#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
require_yq
require_jq
init_config_file

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

load_project_config

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    TASK_ID=$(yq -r '.tasks[] | select(.status == "routed") | .id' "$TASKS_PATH" | head -n1)
  fi
  if [ -z "$TASK_ID" ]; then
    echo "No runnable tasks found" >&2
    exit 1
  fi
fi

log_err "[run] task=$TASK_ID starting"
export TASK_ID

# Per-task lock to avoid double-run across multiple watchers.
# Must be checked BEFORE the cleanup trap so failed lock attempts exit cleanly.
TASK_LOCK="${LOCK_PATH}.task.${TASK_ID}"
TASK_LOCK_OWNED=false
if ! mkdir "$TASK_LOCK" 2>/dev/null; then
  lock_pid=""
  if [ -f "$TASK_LOCK/pid" ]; then
    lock_pid=$(cat "$TASK_LOCK/pid" 2>/dev/null || true)
  fi
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" >/dev/null 2>&1; then
    exit 0
  fi
  if lock_is_stale "$TASK_LOCK"; then
    rmdir "$TASK_LOCK" 2>/dev/null || true
  fi
  if ! mkdir "$TASK_LOCK" 2>/dev/null; then
    exit 0
  fi
fi
TASK_LOCK_OWNED=true
echo "$$" > "$TASK_LOCK/pid"

# Combined cleanup: recover crashed tasks AND release per-task lock.
# Must be a single trap because bash replaces previous EXIT traps.
_run_task_cleanup() {
  local exit_code=$?

  # Only release lock if we own it
  if [ "$TASK_LOCK_OWNED" = true ]; then
    rm -f "$TASK_LOCK/pid"
    rmdir "$TASK_LOCK" 2>/dev/null || true
  fi

  # Recover crashed tasks so they don't stay in_progress forever
  if [ $exit_code -ne 0 ] && [ "$TASK_LOCK_OWNED" = true ]; then
    log_err "[run] task=$TASK_ID crashed (exit=$exit_code) at line ${BASH_LINENO[0]:-?}"
    local current_status
    current_status=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .status" "$TASKS_PATH" 2>/dev/null || true)
    if [ "$current_status" = "routed" ] || [ "$current_status" = "in_progress" ] || [ "$current_status" = "new" ]; then
      local now
      now=$(now_iso 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
      export now
      yq -i \
        "(.tasks[] | select(.id == $TASK_ID) | .status) = \"blocked\" | \
         (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"run_task crashed (exit $exit_code)\" | \
         (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(now)" \
        "$TASKS_PATH" 2>/dev/null || true
    fi
  fi
}
trap '_run_task_cleanup' EXIT

# Read task's dir field and override PROJECT_DIR if set
TASK_DIR=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .dir // \"\"" "$TASKS_PATH")
if [ -n "$TASK_DIR" ] && [ "$TASK_DIR" != "null" ] && [ -d "$TASK_DIR" ]; then
  PROJECT_DIR="$TASK_DIR"
  export PROJECT_DIR
  load_project_config
fi

# Load all task fields in one pass
load_task "$TASK_ID"

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  echo "Task $TASK_ID not found" >&2
  exit 1
fi

if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
  TASK_AGENT=$("$(dirname "$0")/route_task.sh" "$TASK_ID")
  load_task "$TASK_ID"
fi

if [ -z "$TASK_AGENT" ] || [ "$TASK_AGENT" = "null" ]; then
  log_err "[run] task=$TASK_ID missing agent after routing"
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "router did not set agent"
  exit 0
fi

# Build GitHub issue reference for agent prompt
export GH_ISSUE_REF=""
if [ -n "${GH_ISSUE_NUMBER:-}" ] && [ "$GH_ISSUE_NUMBER" != "null" ] && [ "$GH_ISSUE_NUMBER" != "0" ]; then
  GH_REPO=$(config_get '.gh.repo // ""')
  if [ -n "$GH_REPO" ] && [ "$GH_REPO" != "null" ]; then
    GH_ISSUE_REF="#${GH_ISSUE_NUMBER} (${GH_REPO})"
  else
    GH_ISSUE_REF="#${GH_ISSUE_NUMBER}"
  fi
fi

# Merge required skills into selected skills
REQUIRED_SKILLS_CSV=$(config_get '.workflow.required_skills // [] | join(",")')
if [ -n "$REQUIRED_SKILLS_CSV" ]; then
  if [ -n "${SELECTED_SKILLS:-}" ]; then
    SELECTED_SKILLS="${SELECTED_SKILLS},${REQUIRED_SKILLS_CSV}"
  else
    SELECTED_SKILLS="$REQUIRED_SKILLS_CSV"
  fi
fi

# Build context enrichment
export TASK_CONTEXT
TASK_CONTEXT=$(load_task_context "$TASK_ID" "$ROLE")
export PARENT_CONTEXT
PARENT_CONTEXT=$(build_parent_context "$TASK_ID")
export PROJECT_INSTRUCTIONS
PROJECT_INSTRUCTIONS=$(build_project_instructions "$PROJECT_DIR")
export SKILLS_DOCS
SKILLS_DOCS=$(build_skills_docs "${SELECTED_SKILLS:-}")
export REPO_TREE
REPO_TREE=$(build_repo_tree "$PROJECT_DIR")
export GIT_DIFF
if [ "$ATTEMPTS" -gt 0 ]; then
  GIT_DIFF=$(build_git_diff "$PROJECT_DIR")
else
  GIT_DIFF=""
fi

# Output file for agentic mode
ensure_state_dir
OUTPUT_FILE="${STATE_DIR}/output-${TASK_ID}.json"
rm -f "$OUTPUT_FILE"
export OUTPUT_FILE

ATTEMPTS=$((ATTEMPTS + 1))
NOW=$(now_iso)
export NOW ATTEMPTS

# Check max attempts before starting
MAX=$(max_attempts)
if [ "$ATTEMPTS" -gt "$MAX" ]; then
  log_err "[run] task=$TASK_ID exceeded max attempts ($MAX)"
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"blocked\" | \
     (.tasks[] | select(.id == $TASK_ID) | .reason) = \"exceeded max attempts ($MAX)\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"max attempts exceeded\" | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "blocked" "exceeded max attempts ($MAX)"
  exit 0
fi

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = \"in_progress\" | \
   (.tasks[] | select(.id == $TASK_ID) | .attempts) = (env(ATTEMPTS) | tonumber) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

append_history "$TASK_ID" "in_progress" "started attempt $ATTEMPTS"

# Detect decompose/plan mode
DECOMPOSE=false
LABELS_LOWER=$(printf '%s' "$TASK_LABELS" | tr '[:upper:]' '[:lower:]')
if printf '%s' "$LABELS_LOWER" | grep -qE '(^|,)plan(,|$)'; then
  DECOMPOSE=true
fi

# Build system prompt and agent message
if [ "$DECOMPOSE" = true ] && [ "$ATTEMPTS" -le 1 ]; then
  log_err "[run] task=$TASK_ID using plan/decompose mode"
  SYSTEM_PROMPT=$(render_template "$SCRIPT_DIR/../prompts/plan.md")
else
  SYSTEM_PROMPT=$(render_template "$SCRIPT_DIR/../prompts/system.md")
fi
AGENT_MESSAGE=$(render_template "$SCRIPT_DIR/../prompts/agent.md")

require_agent "$TASK_AGENT"

# Build disallowed tools list
DISALLOWED_TOOLS=$(config_get '.workflow.disallowed_tools // ["Bash(rm *)","Bash(rm -*)"] | join(",")')

# Save prompt for debugging
ensure_state_dir
PROMPT_FILE="${STATE_DIR}/prompt-${TASK_ID}.txt"
printf '=== SYSTEM PROMPT ===\n%s\n\n=== AGENT MESSAGE ===\n%s\n' "$SYSTEM_PROMPT" "$AGENT_MESSAGE" > "$PROMPT_FILE"
PROMPT_HASH=$(shasum -a 256 "$PROMPT_FILE" | cut -c1-8)
export PROMPT_HASH
with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .prompt_hash) = strenv(PROMPT_HASH)" \
  "$TASKS_PATH"
log_err "[run] task=$TASK_ID prompt saved to $PROMPT_FILE (hash=$PROMPT_HASH)"
log_err "[run] task=$TASK_ID agent=$TASK_AGENT model=${AGENT_MODEL:-default} attempt=$ATTEMPTS project=$PROJECT_DIR"
log_err "[run] task=$TASK_ID skills=${SELECTED_SKILLS:-none} issue=${GH_ISSUE_REF:-none}"

start_spinner "Running task $TASK_ID ($TASK_AGENT)"
AGENT_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESPONSE=""
STDERR_FILE="${STATE_DIR}/stderr-${TASK_ID}.txt"
CMD_STATUS=0
case "$TASK_AGENT" in
  claude)
    log_err "[run] cmd: claude -p ${AGENT_MODEL:+--model $AGENT_MODEL} --output-format json --append-system-prompt <prompt> <message>"
    DISALLOW_ARGS=()
    if [ -n "$DISALLOWED_TOOLS" ]; then
      IFS=',' read -ra _tools <<< "$DISALLOWED_TOOLS"
      for _t in "${_tools[@]}"; do
        DISALLOW_ARGS+=(--disallowedTools "$_t")
      done
    fi
    RESPONSE=$(cd "$PROJECT_DIR" && run_with_timeout claude -p \
      ${AGENT_MODEL:+--model "$AGENT_MODEL"} \
      "${DISALLOW_ARGS[@]}" \
      --output-format json \
      --append-system-prompt "$SYSTEM_PROMPT" \
      "$AGENT_MESSAGE" 2>"$STDERR_FILE") || CMD_STATUS=$?
    ;;
  codex)
    log_err "[run] cmd: codex -q ${AGENT_MODEL:+--model $AGENT_MODEL} --json <message>"
    FULL_MESSAGE="${SYSTEM_PROMPT}

${AGENT_MESSAGE}"
    RESPONSE=$(cd "$PROJECT_DIR" && run_with_timeout codex -q \
      ${AGENT_MODEL:+--model "$AGENT_MODEL"} \
      --json \
      "$FULL_MESSAGE" 2>"$STDERR_FILE") || CMD_STATUS=$?
    ;;
  opencode)
    log_err "[run] cmd: opencode run --format json <message>"
    FULL_MESSAGE="${SYSTEM_PROMPT}

${AGENT_MESSAGE}"
    RESPONSE=$(cd "$PROJECT_DIR" && run_with_timeout opencode run \
      --format json \
      "$FULL_MESSAGE" 2>"$STDERR_FILE") || CMD_STATUS=$?
    ;;
  *)
    echo "Unknown agent: $TASK_AGENT" >&2
    exit 1
    ;;
esac

stop_spinner
AGENT_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log_err "[run] task=$TASK_ID agent finished (exit=$CMD_STATUS) started=$AGENT_START ended=$AGENT_END"

# Save raw response for debugging
RESPONSE_FILE="${STATE_DIR}/response-${TASK_ID}.txt"
printf '%s' "$RESPONSE" > "$RESPONSE_FILE"
RESPONSE_LEN=${#RESPONSE}
log_err "[run] task=$TASK_ID response saved to $RESPONSE_FILE (${RESPONSE_LEN} bytes)"

# Log stderr even on success (agents may print warnings)
AGENT_STDERR=""
if [ -f "$STDERR_FILE" ] && [ -s "$STDERR_FILE" ]; then
  AGENT_STDERR=$(cat "$STDERR_FILE")
  log_err "[run] task=$TASK_ID stderr: $AGENT_STDERR"
fi

# Classify error from exit code, stderr, and stdout
if [ "$CMD_STATUS" -ne 0 ]; then
  COMBINED_OUTPUT="${RESPONSE}${AGENT_STDERR}"

  # Detect auth/token/billing errors
  if printf '%s' "$COMBINED_OUTPUT" | grep -qiE 'unauthorized|invalid.*(api|key|token)|auth.*fail|401|403|no.*(api|key|token)|expired.*(key|token|plan)|billing|quota|rate.limit|insufficient.*credit|payment.*required'; then
    log_err "[run] task=$TASK_ID AUTH/BILLING ERROR detected for agent=$TASK_AGENT"
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "auth/billing error for $TASK_AGENT — check API key or credits"
    exit 0
  fi

  # Detect timeout
  if [ "$CMD_STATUS" -eq 124 ]; then
    log_err "[run] task=$TASK_ID TIMEOUT"
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent timed out (exit 124)"
    exit 0
  fi

  log_err "[run] task=$TASK_ID agent command failed exit=$CMD_STATUS"
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent command failed (exit $CMD_STATUS)"
  exit 0
fi

# Read structured output from file (primary), fall back to stdout parsing
RESPONSE_JSON=""
if [ -f "$OUTPUT_FILE" ]; then
  RESPONSE_JSON=$(cat "$OUTPUT_FILE")
  log_err "[run] read output from $OUTPUT_FILE"
else
  log_err "[run] output file not found, trying stdout fallback"
  RESPONSE_JSON=$(normalize_json_response "$RESPONSE" 2>/dev/null || true)
fi

if [ -z "$RESPONSE_JSON" ]; then
  log_err "[run] task=$TASK_ID invalid JSON response"
  mkdir -p "$CONTEXTS_DIR"
  printf '%s' "$RESPONSE" > "${CONTEXTS_DIR}/response-${TASK_ID}.md"
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent response invalid YAML/JSON"
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
REASON=$(printf '%s' "$RESPONSE_JSON" | jq -r '.reason // ""')
DELEGATIONS_JSON=$(printf '%s' "$RESPONSE_JSON" | jq -c '.delegations // []')

if [ -z "$AGENT_STATUS" ] || [ "$AGENT_STATUS" = "null" ]; then
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent response missing status"
  exit 0
fi

NOW=$(now_iso)
export AGENT_STATUS SUMMARY NEEDS_HELP NOW FILES_CHANGED_STR ACCOMPLISHED_STR REMAINING_STR BLOCKERS_STR REASON

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .status) = strenv(AGENT_STATUS) | \
   (.tasks[] | select(.id == $TASK_ID) | .summary) = strenv(SUMMARY) | \
   (.tasks[] | select(.id == $TASK_ID) | .reason) = strenv(REASON) | \
   (.tasks[] | select(.id == $TASK_ID) | .accomplished) = (strenv(ACCOMPLISHED_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .remaining) = (strenv(REMAINING_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .blockers) = (strenv(BLOCKERS_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .files_changed) = (strenv(FILES_CHANGED_STR) | split(\"\\n\") | map(select(length > 0))) | \
   (.tasks[] | select(.id == $TASK_ID) | .needs_help) = (strenv(NEEDS_HELP) == \"true\") | \
   (.tasks[] | select(.id == $TASK_ID) | .last_error) = null | \
   (.tasks[] | select(.id == $TASK_ID) | .retry_at) = null | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

# Build history note with reason if present
HISTORY_NOTE="agent completed"
if [ -n "$REASON" ] && [ "$REASON" != "null" ]; then
  HISTORY_NOTE="agent completed: $REASON"
fi
append_history "$TASK_ID" "$AGENT_STATUS" "$HISTORY_NOTE"

FILES_CHANGED=$(printf '%s' "$RESPONSE_JSON" | jq -r '.files_changed | join(", ")')
append_task_context "$TASK_ID" "[$NOW] status: $AGENT_STATUS\nsummary: $SUMMARY\nreason: $REASON\nfiles: $FILES_CHANGED\n"

# Optional review step
ENABLE_REVIEW_AGENT=${ENABLE_REVIEW_AGENT:-$(config_get '.workflow.enable_review_agent // false')}
REVIEW_AGENT=${REVIEW_AGENT:-$(config_get '.workflow.review_agent // "claude"')}

if [ "$AGENT_STATUS" = "done" ] && [ "$ENABLE_REVIEW_AGENT" = "true" ]; then
  FILES_CHANGED=$(printf '%s' "$RESPONSE_JSON" | jq -r '.files_changed | join(", ")')

  # Build review context with git diff
  export TASK_SUMMARY="$SUMMARY"
  export TASK_FILES_CHANGED="$FILES_CHANGED"
  export GIT_DIFF
  GIT_DIFF=$(build_git_diff "$PROJECT_DIR")

  REVIEW_PROMPT=$(render_template "$SCRIPT_DIR/../prompts/review.md")

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
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "review agent failed"
    exit 0
  fi

  REVIEW_DECISION=$(printf '%s' "$REVIEW_RESPONSE" | yq -r '.decision // ""')
  REVIEW_NOTES=$(printf '%s' "$REVIEW_RESPONSE" | yq -r '.notes // ""')

  if [ "$REVIEW_DECISION" = "request_changes" ]; then
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "review requested changes"
    exit 0
  fi

  NOW=$(now_iso)
  export NOW REVIEW_NOTES
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .review_decision) = \"approve\" | \
     (.tasks[] | select(.id == $TASK_ID) | .review_notes) = strenv(REVIEW_NOTES) | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "done" "review approved"
fi

DELEG_COUNT=$(printf '%s' "$DELEGATIONS_JSON" | jq -r 'length')

if [ "$DELEG_COUNT" -gt 0 ]; then
  acquire_lock

  MAX_ID=$(yq -r '(.tasks | map(.id) | max) // 0' "$TASKS_PATH")
  CHILD_IDS=()
  for i in $(seq 0 $((DELEG_COUNT - 1))); do
    D_TITLE=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].title // \"\"")
    D_BODY=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].body // \"\"")
    D_LABELS=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].labels // [] | join(\",\")")
    D_AGENT=$(printf '%s' "$DELEGATIONS_JSON" | jq -r ".[$i].suggested_agent // \"\"")

    MAX_ID=$((MAX_ID + 1))
    NOW=$(now_iso)
    export NOW PROJECT_DIR

    create_task_entry "$MAX_ID" "$D_TITLE" "$D_BODY" "$D_LABELS" "$TASK_ID" "$D_AGENT"

    yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .children) += [$MAX_ID]" \
      "$TASKS_PATH"

    CHILD_IDS+=("$MAX_ID")
  done

  NOW=$(now_iso)
  export NOW
  yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"blocked\" | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
    "$TASKS_PATH"

  release_lock

  printf 'Spawned children: %s\n' "${CHILD_IDS[*]}"
  append_history "$TASK_ID" "blocked" "spawned children: ${CHILD_IDS[*]}"
fi

log_err "[run] task=$TASK_ID DONE status=$AGENT_STATUS agent=$TASK_AGENT attempt=$ATTEMPTS started=$AGENT_START ended=$AGENT_END"
