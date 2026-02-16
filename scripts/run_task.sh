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
    log_err "No runnable tasks found"
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
    rm -f "$TASK_LOCK/pid"
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
if [ -n "$TASK_DIR" ] && [ "$TASK_DIR" != "null" ]; then
  if [ -d "$TASK_DIR" ]; then
    PROJECT_DIR="$TASK_DIR"
    export PROJECT_DIR
    load_project_config
  else
    log_err "[run] task=$TASK_ID dir=$TASK_DIR does not exist"
    append_history "$TASK_ID" "blocked" "task dir does not exist: $TASK_DIR"
    set_task_field "$TASK_ID" "status" "blocked"
    set_task_field "$TASK_ID" "last_error" "task dir does not exist: $TASK_DIR"
    exit 0
  fi
fi

# Load all task fields in one pass
load_task "$TASK_ID"

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  log_err "Task $TASK_ID not found"
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

# Fetch GitHub issue comments for agent context
export ISSUE_COMMENTS=""
if [ -n "${GH_ISSUE_NUMBER:-}" ] && [ "$GH_ISSUE_NUMBER" != "null" ] && [ "$GH_ISSUE_NUMBER" != "0" ]; then
  GH_REPO=$(config_get '.gh.repo // ""')
  if [ -n "$GH_REPO" ] && [ "$GH_REPO" != "null" ]; then
    ISSUE_COMMENTS=$(fetch_issue_comments "$GH_REPO" "$GH_ISSUE_NUMBER" 10)
  fi
fi

# Set up worktree for coding tasks — orchestrator creates it, not the agent
export WORKTREE_DIR=""
DECOMPOSE=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .decompose // false" "$TASKS_PATH")
if [ "$DECOMPOSE" = "true" ]; then
  log_err "[run] task=$TASK_ID decompose=true, skipping worktree (planning task)"
elif [ -n "${GH_ISSUE_NUMBER:-}" ] && [ "$GH_ISSUE_NUMBER" != "null" ] && [ "$GH_ISSUE_NUMBER" != "0" ]; then
  PROJECT_NAME=$(basename "$PROJECT_DIR")
  BRANCH_SLUG=$(printf '%s' "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 40)
  BRANCH_NAME="gh-task-${GH_ISSUE_NUMBER}-${BRANCH_SLUG}"
  WORKTREE_DIR="$HOME/.worktrees/${PROJECT_NAME}/${BRANCH_NAME}"
  export BRANCH_NAME

  if [ ! -d "$WORKTREE_DIR" ]; then
    log_err "[run] task=$TASK_ID creating worktree at $WORKTREE_DIR"
    # Register branch with GitHub issue
    cd "$PROJECT_DIR" && gh issue develop "$GH_ISSUE_NUMBER" --base main --name "$BRANCH_NAME" 2>/dev/null || true
    # Create branch if it doesn't exist
    cd "$PROJECT_DIR" && git branch "$BRANCH_NAME" main 2>/dev/null || true
    # Create worktree
    mkdir -p "$(dirname "$WORKTREE_DIR")"
    cd "$PROJECT_DIR" && git worktree add "$WORKTREE_DIR" "$BRANCH_NAME" 2>/dev/null || true
  fi

  if [ -d "$WORKTREE_DIR" ]; then
    PROJECT_DIR="$WORKTREE_DIR"
    export PROJECT_DIR
    log_err "[run] task=$TASK_ID agent will run in worktree $WORKTREE_DIR"
  else
    # Retry: clean up and try again
    log_err "[run] task=$TASK_ID worktree creation failed, retrying"
    cd "$PROJECT_DIR" && git worktree prune 2>/dev/null || true
    cd "$PROJECT_DIR" && git branch -D "$BRANCH_NAME" 2>/dev/null || true
    cd "$PROJECT_DIR" && git branch "$BRANCH_NAME" main 2>/dev/null || true
    cd "$PROJECT_DIR" && git worktree add "$WORKTREE_DIR" "$BRANCH_NAME" 2>/dev/null || true
    if [ -d "$WORKTREE_DIR" ]; then
      PROJECT_DIR="$WORKTREE_DIR"
      export PROJECT_DIR
      log_err "[run] task=$TASK_ID worktree created on retry: $WORKTREE_DIR"
    else
      log_err "[run] task=$TASK_ID worktree creation failed, blocking task"
      append_history "$TASK_ID" "blocked" "worktree creation failed for $WORKTREE_DIR"
      set_task_field "$TASK_ID" "status" "blocked"
      set_task_field "$TASK_ID" "last_error" "worktree creation failed: $WORKTREE_DIR"
      exit 0
    fi
  fi
fi

# Extract error history and last_error for agent context
export TASK_HISTORY=""
TASK_HISTORY=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .history // [] |
  .[-5:] | .[] | \"[\(.ts)] \(.status): \(.note)\"" "$TASKS_PATH" 2>/dev/null || true)
export TASK_LAST_ERROR=""
TASK_LAST_ERROR=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .last_error // \"\"" "$TASKS_PATH")

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

# Detect retry loops: if 4+ attempts and last 3 blocked entries have identical notes, stop
if [ "$ATTEMPTS" -ge 4 ]; then
  BLOCKED_NOTES=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .history // [] |
    map(select(.status == \"blocked\")) | .[-3:] | map(.note) | unique | length" "$TASKS_PATH" 2>/dev/null || echo "0")
  BLOCKED_COUNT=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .history // [] |
    map(select(.status == \"blocked\")) | .[-3:] | length" "$TASKS_PATH" 2>/dev/null || echo "0")
  if [ "$BLOCKED_COUNT" -ge 3 ] && [ "$BLOCKED_NOTES" -eq 1 ]; then
    error_log "[run] task=$TASK_ID retry loop detected (same error 3x)"
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "retry loop: same error repeated 3 times"
    exit 0
  fi
fi

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
: > "$STDERR_FILE"

# Monitor stderr in background for stuck agent indicators (1Password, passphrase, etc.)
MONITOR_PID=""
MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
(
  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -f "$STDERR_FILE" ] || continue
    STDERR_SIZE=$(wc -c < "$STDERR_FILE" 2>/dev/null || echo 0)
    if [ "$STDERR_SIZE" -gt 0 ]; then
      if grep -qiE 'waiting.*approv|passphrase|unlock|1password|biometric|touch.id|press.*button|enter.*password|interactive.*auth|permission.*denied.*publickey|sign_and_send_pubkey' "$STDERR_FILE" 2>/dev/null; then
        error_log "[run] task=$TASK_ID WARNING: agent may be stuck waiting for interactive approval"
        error_log "[run] task=$TASK_ID stderr: $(tail -c 300 "$STDERR_FILE")"
      fi
    fi
  done
) &
MONITOR_PID=$!
cleanup_monitor() { kill "$MONITOR_PID" 2>/dev/null || true; wait "$MONITOR_PID" 2>/dev/null || true; }

# Set git identity for agent commits
export GIT_AUTHOR_NAME="${TASK_AGENT}[bot]"
export GIT_COMMITTER_NAME="${TASK_AGENT}[bot]"
export GIT_AUTHOR_EMAIL="${TASK_AGENT}[bot]@users.noreply.github.com"
export GIT_COMMITTER_EMAIL="${TASK_AGENT}[bot]@users.noreply.github.com"

# Map model names to agent-specific equivalents
map_model() {
  local agent="$1" model="$2"
  if [ "$agent" = "codex" ]; then
    case "$model" in
      opus|claude-opus*) echo "gpt-5.3-codex" ;;
      sonnet|claude-sonnet*) echo "gpt-5.2" ;;
      haiku|claude-haiku*) echo "gpt-5.1-codex-mini" ;;
      *) echo "$model" ;;
    esac
  else
    echo "$model"
  fi
}
if [ -n "$AGENT_MODEL" ]; then
  AGENT_MODEL=$(map_model "$TASK_AGENT" "$AGENT_MODEL")
fi

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
      --permission-mode acceptEdits \
      --allowedTools "Write" \
      "${DISALLOW_ARGS[@]}" \
      --output-format json \
      --append-system-prompt "$SYSTEM_PROMPT" \
      "$AGENT_MESSAGE" 2>"$STDERR_FILE") || CMD_STATUS=$?
    ;;
  codex)
    log_err "[run] cmd: codex exec ${AGENT_MODEL:+-m $AGENT_MODEL} --json <stdin>"
    FULL_MESSAGE="${SYSTEM_PROMPT}

${AGENT_MESSAGE}"
    RESPONSE=$(cd "$PROJECT_DIR" && printf '%s' "$FULL_MESSAGE" | run_with_timeout codex exec \
      ${AGENT_MODEL:+-m "$AGENT_MODEL"} \
      --json \
      - 2>"$STDERR_FILE") || CMD_STATUS=$?
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
    log_err "[run] task=$TASK_ID unknown agent: $TASK_AGENT"
    exit 1
    ;;
esac

stop_spinner
cleanup_monitor
AGENT_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Calculate duration in seconds (macOS and Linux compatible)
AGENT_START_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$AGENT_START" +%s 2>/dev/null || date -d "$AGENT_START" +%s 2>/dev/null || echo 0)
AGENT_END_EPOCH=$(date +%s)
AGENT_DURATION=$((AGENT_END_EPOCH - AGENT_START_EPOCH))
export AGENT_DURATION
log_err "[run] task=$TASK_ID agent finished (exit=$CMD_STATUS) duration=$(duration_fmt $AGENT_DURATION)"

# Save raw response for debugging
RESPONSE_FILE="${STATE_DIR}/response-${TASK_ID}.txt"
printf '%s' "$RESPONSE" > "$RESPONSE_FILE"
RESPONSE_LEN=${#RESPONSE}
log_err "[run] task=$TASK_ID response saved to $RESPONSE_FILE (${RESPONSE_LEN} bytes)"

# Extract tool history from agent response (for debugging and retry context)
TOOL_SUMMARY=$(RAW_RESPONSE="$RESPONSE" python3 "$SCRIPT_DIR/normalize_json.py" --tool-summary 2>/dev/null || true)
TOOL_COUNT=0
if [ -n "$TOOL_SUMMARY" ]; then
  RAW_RESPONSE="$RESPONSE" python3 "$SCRIPT_DIR/normalize_json.py" --tool-history > "${STATE_DIR}/tools-${TASK_ID}.json" 2>/dev/null || true
  append_task_context "$TASK_ID" "Commands run by agent (attempt $ATTEMPTS):\n$TOOL_SUMMARY"
  TOOL_COUNT=$(printf '%s' "$TOOL_SUMMARY" | wc -l | tr -d ' ')
  log_err "[run] task=$TASK_ID tool history saved ($TOOL_COUNT calls)"
fi

# Extract token usage
INPUT_TOKENS=0
OUTPUT_TOKENS=0
USAGE_JSON=$(RAW_RESPONSE="$RESPONSE" python3 "$SCRIPT_DIR/normalize_json.py" --usage 2>/dev/null || true)
if [ -n "$USAGE_JSON" ]; then
  INPUT_TOKENS=$(printf '%s' "$USAGE_JSON" | jq -r '.input_tokens // 0')
  OUTPUT_TOKENS=$(printf '%s' "$USAGE_JSON" | jq -r '.output_tokens // 0')
fi

# Log stderr even on success (agents may print warnings)
AGENT_STDERR=""
if [ -f "$STDERR_FILE" ] && [ -s "$STDERR_FILE" ]; then
  AGENT_STDERR=$(cat "$STDERR_FILE")
  log_err "[run] task=$TASK_ID stderr: $(printf '%s' "$AGENT_STDERR" | head -c 200)"
fi

# Classify error from exit code, stderr, and stdout
if [ "$CMD_STATUS" -ne 0 ]; then
  COMBINED_OUTPUT="${RESPONSE}${AGENT_STDERR}"

  # Detect auth/token/billing errors
  if printf '%s' "$COMBINED_OUTPUT" | grep -qiE 'unauthorized|invalid.*(api|key|token)|auth.*fail|401|403|no.*(api|key|token)|expired.*(key|token|plan)|billing|quota|rate.limit|insufficient.*credit|payment.*required'; then
    error_log "[run] task=$TASK_ID AUTH/BILLING ERROR for agent=$TASK_AGENT"
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "auth/billing error for $TASK_AGENT — check API key or credits"
    exit 0
  fi

  # Detect timeout
  if [ "$CMD_STATUS" -eq 124 ]; then
    # Check if timeout was caused by interactive approval prompt
    TIMEOUT_REASON="agent timed out (exit 124)"
    if [ -f "$STDERR_FILE" ] && grep -qiE 'waiting.*approv|passphrase|unlock|1password|biometric|touch.id|press.*button|enter.*password|interactive.*auth|permission.*denied.*publickey|sign_and_send_pubkey' "$STDERR_FILE" 2>/dev/null; then
      TIMEOUT_REASON="agent stuck waiting for interactive approval (1Password/SSH/passphrase) — configure headless auth"
      error_log "[run] task=$TASK_ID TIMEOUT: stuck on interactive approval"
    else
      error_log "[run] task=$TASK_ID TIMEOUT after $(duration_fmt $AGENT_DURATION)"
    fi
    mark_needs_review "$TASK_ID" "$ATTEMPTS" "$TIMEOUT_REASON"
    exit 0
  fi

  error_log "[run] task=$TASK_ID agent command failed exit=$CMD_STATUS"
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent command failed (exit $CMD_STATUS)"
  exit 0
fi

# Read structured output from file (primary), fall back to stdout parsing
RESPONSE_JSON=""
if [ -f "$OUTPUT_FILE" ]; then
  RESPONSE_JSON=$(cat "$OUTPUT_FILE")
  log_err "[run] read output from $OUTPUT_FILE"
else
  # Check if agent wrote output inside project dir instead
  ALT_OUTPUT="${PROJECT_DIR}/.orchestrator/output-${TASK_ID}.json"
  if [ -f "$ALT_OUTPUT" ]; then
    RESPONSE_JSON=$(cat "$ALT_OUTPUT")
    log_err "[run] read output from $ALT_OUTPUT (project dir fallback)"
  else
    log_err "[run] output file not found, trying stdout fallback"
    RESPONSE_JSON=$(normalize_json_response "$RESPONSE" 2>/dev/null || true)
  fi
fi

if [ -z "$RESPONSE_JSON" ]; then
  log_err "[run] task=$TASK_ID invalid JSON response"
  mkdir -p "$CONTEXTS_DIR"
  printf '%s' "$RESPONSE" > "${CONTEXTS_DIR}/response-${TASK_ID}.md"
  mark_needs_review "$TASK_ID" "$ATTEMPTS" "agent response invalid YAML/JSON"
  exit 0
fi

# Inject agent/model metadata if not already present
RESPONSE_JSON=$(printf '%s' "$RESPONSE_JSON" | jq \
  --arg agent "$TASK_AGENT" \
  --arg model "${AGENT_MODEL:-default}" \
  '. + {agent: (.agent // $agent), model: (.model // $model)}')

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

# Store agent metadata
RESP_AGENT=$(printf '%s' "$RESPONSE_JSON" | jq -r '.agent // ""')
RESP_MODEL=$(printf '%s' "$RESPONSE_JSON" | jq -r '.model // ""')
export RESP_MODEL
STDERR_SNIPPET=""
if [ -n "$AGENT_STDERR" ]; then
  STDERR_SNIPPET=$(printf '%s' "$AGENT_STDERR" | tail -c 500)
fi
export STDERR_SNIPPET

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
   (.tasks[] | select(.id == $TASK_ID) | .duration) = $AGENT_DURATION | \
   (.tasks[] | select(.id == $TASK_ID) | .input_tokens) = $INPUT_TOKENS | \
   (.tasks[] | select(.id == $TASK_ID) | .output_tokens) = $OUTPUT_TOKENS | \
   (.tasks[] | select(.id == $TASK_ID) | .agent_model) = strenv(RESP_MODEL) | \
   (.tasks[] | select(.id == $TASK_ID) | .stderr_snippet) = strenv(STDERR_SNIPPET) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

# Push agent's branch if there are local commits not on remote
if [ "$AGENT_STATUS" = "done" ] || [ "$AGENT_STATUS" = "in_progress" ]; then
  if [ -d "$PROJECT_DIR" ] && (cd "$PROJECT_DIR" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    CURRENT_BRANCH=$(cd "$PROJECT_DIR" && git branch --show-current 2>/dev/null || true)
    if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
      if (cd "$PROJECT_DIR" && git log "origin/${CURRENT_BRANCH}..HEAD" --oneline 2>/dev/null | grep -q .); then
        log_err "[run] task=$TASK_ID pushing branch $CURRENT_BRANCH"
        # Use HTTPS rewrite to avoid SSH/1Password interactive prompts
        if ! (cd "$PROJECT_DIR" && git \
          -c "url.https://github.com/.insteadOf=git@github.com:" \
          push -u origin "$CURRENT_BRANCH" 2>>"$STDERR_FILE"); then
          error_log "[run] task=$TASK_ID failed to push branch $CURRENT_BRANCH"
        fi

        # Create PR if branch was pushed and no PR exists yet
        if command -v gh >/dev/null 2>&1; then
          EXISTING_PR=$(cd "$PROJECT_DIR" && gh pr list --head "$CURRENT_BRANCH" --json number -q '.[0].number' 2>/dev/null || true)
          if [ -z "$EXISTING_PR" ]; then
            PR_TITLE="${SUMMARY:-$TASK_TITLE}"
            PR_BODY="## Summary

${REASON:-Agent task completed.}

Closes #${GH_ISSUE_NUMBER:-}

---
*Created by ${TASK_AGENT}[bot] via [Orchestrator](https://github.com/gabrielkoerich/orchestrator)*"
            PR_URL=$(cd "$PROJECT_DIR" && gh pr create \
              --title "$PR_TITLE" \
              --body "$PR_BODY" \
              --head "$CURRENT_BRANCH" 2>>"$STDERR_FILE" || true)
            if [ -n "$PR_URL" ]; then
              log_err "[run] task=$TASK_ID created PR: $PR_URL"
            else
              log_err "[run] task=$TASK_ID failed to create PR for $CURRENT_BRANCH"
            fi
          fi
        fi
      fi
    fi
  fi
fi

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
      log_err "[run] task=$TASK_ID unknown review agent: $REVIEW_AGENT"
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

log_err "[run] task=$TASK_ID DONE status=$AGENT_STATUS agent=$TASK_AGENT model=${RESP_MODEL:-${AGENT_MODEL:-default}} attempt=$ATTEMPTS duration=$(duration_fmt $AGENT_DURATION) tokens=${INPUT_TOKENS}in/${OUTPUT_TOKENS}out tools=$TOOL_COUNT"
