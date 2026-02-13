#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/lib.sh"
require_yq
require_jq
init_tasks_file
init_jobs_file
init_config_file
load_project_config

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR

# Router agent config (reuse same agent/model as router)
CHAT_AGENT=${CHAT_AGENT:-$(config_get '.router.agent // "claude"')}
CHAT_MODEL=${CHAT_MODEL:-$(config_get '.router.model // ""')}
require_agent "$CHAT_AGENT"

# Session history (PID-scoped, cleaned up on exit)
ensure_state_dir
HISTORY_FILE="${STATE_DIR}/chat-history-$$.txt"
touch "$HISTORY_FILE"
cleanup() {
  rm -f "$HISTORY_FILE"
  stop_spinner 2>/dev/null || true
}
trap cleanup EXIT

MAX_HISTORY=10

# Double Ctrl-C to exit
SIGINT_COUNT=0
SIGINT_LAST=0
handle_sigint() {
  local now
  now=$(date +%s)
  if [ $((now - SIGINT_LAST)) -le 2 ]; then
    echo ""
    echo "Goodbye!"
    exit 0
  fi
  SIGINT_COUNT=1
  SIGINT_LAST=$now
  # Clear current input line and show hint
  echo ""
  echo "(Press Ctrl-C again to exit)"
  printf '> '
}
trap 'handle_sigint' INT

# Gather current status context
gather_status() {
  "${SCRIPT_DIR}/status.sh" --json 2>/dev/null || echo '{}'
}

# Read last N exchanges from history
read_history() {
  if [ ! -s "$HISTORY_FILE" ]; then
    echo "(no prior messages)"
    return
  fi
  tail -n $((MAX_HISTORY * 2)) "$HISTORY_FILE"
}

# Append an exchange to history
append_exchange() {
  local user_msg="$1"
  local assistant_msg="$2"
  printf 'User: %s\nAssistant: %s\n' "$user_msg" "$assistant_msg" >> "$HISTORY_FILE"
}

# Send message to LLM and get response
call_llm() {
  local prompt="$1"
  local response=""
  local rc=0

  case "$CHAT_AGENT" in
    codex)
      if [ -n "$CHAT_MODEL" ]; then
        response=$(codex exec --model "$CHAT_MODEL" --json "$prompt") || rc=$?
      else
        response=$(codex exec --json "$prompt") || rc=$?
      fi
      ;;
    claude)
      if [ -n "$CHAT_MODEL" ]; then
        response=$(claude --model "$CHAT_MODEL" --output-format json --print "$prompt") || rc=$?
      else
        response=$(claude --output-format json --print "$prompt") || rc=$?
      fi
      ;;
    opencode)
      response=$(opencode run --format json "$prompt") || rc=$?
      ;;
    *)
      echo "Unknown chat agent: $CHAT_AGENT" >&2
      return 1
      ;;
  esac

  if [ "$rc" -ne 0 ]; then
    echo ""
    return "$rc"
  fi
  printf '%s' "$response"
}

# Parse JSON response from LLM, extracting action/params/response
parse_response() {
  local raw="$1"
  local json=""

  # Try normalize_json_response first (handles Claude wrapper + fenced JSON)
  json=$(normalize_json_response "$raw" 2>/dev/null || true)

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e 'type=="object"' >/dev/null 2>&1; then
    # Fallback: maybe it's already valid JSON
    if printf '%s' "$raw" | jq -e 'type=="object"' >/dev/null 2>&1; then
      json="$raw"
    else
      echo ""
      return 1
    fi
  fi

  printf '%s' "$json"
}

# Dispatch an action to the appropriate script
dispatch() {
  local action="$1"
  local params="$2"

  case "$action" in
    add_task)
      local title body labels
      title=$(printf '%s' "$params" | jq -r '.title // ""')
      body=$(printf '%s' "$params" | jq -r '.body // ""')
      labels=$(printf '%s' "$params" | jq -r '.labels // ""')
      "${SCRIPT_DIR}/add_task.sh" "$title" "$body" "$labels"
      ;;
    add_job)
      local schedule title body labels agent
      schedule=$(printf '%s' "$params" | jq -r '.schedule // ""')
      title=$(printf '%s' "$params" | jq -r '.title // ""')
      body=$(printf '%s' "$params" | jq -r '.body // ""')
      labels=$(printf '%s' "$params" | jq -r '.labels // ""')
      agent=$(printf '%s' "$params" | jq -r '.agent // ""')
      "${SCRIPT_DIR}/jobs_add.sh" "$schedule" "$title" "$body" "$labels" "$agent"
      ;;
    list)
      "${SCRIPT_DIR}/list_tasks.sh"
      ;;
    status)
      "${SCRIPT_DIR}/status.sh"
      ;;
    dashboard)
      "${SCRIPT_DIR}/dashboard.sh"
      ;;
    tree)
      "${SCRIPT_DIR}/tree.sh"
      ;;
    jobs_list)
      "${SCRIPT_DIR}/jobs_list.sh"
      ;;
    run)
      local id
      id=$(printf '%s' "$params" | jq -r '.id // ""')
      if [ -n "$id" ] && [ "$id" != "null" ]; then
        "${SCRIPT_DIR}/run_task.sh" "$id"
      else
        "${SCRIPT_DIR}/next.sh"
      fi
      ;;
    set_agent)
      local id agent
      id=$(printf '%s' "$params" | jq -r '.id // ""')
      agent=$(printf '%s' "$params" | jq -r '.agent // ""')
      "${SCRIPT_DIR}/set_agent.sh" "$id" "$agent"
      ;;
    remove_job)
      local id
      id=$(printf '%s' "$params" | jq -r '.id // ""')
      "${SCRIPT_DIR}/jobs_remove.sh" "$id"
      ;;
    enable_job)
      local id
      id=$(printf '%s' "$params" | jq -r '.id // ""')
      yq -i "(.jobs[] | select(.id == \"$id\") | .enabled) = true" "$JOBS_PATH"
      echo "Enabled job '$id'"
      ;;
    disable_job)
      local id
      id=$(printf '%s' "$params" | jq -r '.id // ""')
      yq -i "(.jobs[] | select(.id == \"$id\") | .enabled) = false" "$JOBS_PATH"
      echo "Disabled job '$id'"
      ;;
    quick_task)
      local prompt
      prompt=$(printf '%s' "$params" | jq -r '.prompt // ""')
      echo "Running quick task..."
      case "$CHAT_AGENT" in
        claude)
          if [ -n "$CHAT_MODEL" ]; then
            claude --model "$CHAT_MODEL" --print "$prompt"
          else
            claude --print "$prompt"
          fi
          ;;
        codex)
          if [ -n "$CHAT_MODEL" ]; then
            codex exec --model "$CHAT_MODEL" "$prompt"
          else
            codex exec "$prompt"
          fi
          ;;
        opencode)
          opencode run "$prompt"
          ;;
      esac
      ;;
    answer)
      # No dispatch needed — just show the response
      ;;
    *)
      echo "Unknown action: $action"
      ;;
  esac
}

# Main REPL loop
echo "orchestrator chat (type 'exit' to quit)"
echo ""

while true; do
  # Prompt
  printf '> '

  # Read input (exit on EOF / Ctrl-D)
  if ! IFS= read -r USER_INPUT; then
    echo ""
    break
  fi

  # Trim whitespace
  USER_INPUT=$(printf '%s' "$USER_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Skip empty input
  if [ -z "$USER_INPUT" ]; then
    continue
  fi

  # Exit commands
  case "$USER_INPUT" in
    exit|quit|q|bye)
      echo "Goodbye!"
      break
      ;;
  esac

  # Gather context
  STATUS_JSON=$(gather_status)
  CHAT_HISTORY=$(read_history)
  export STATUS_JSON CHAT_HISTORY PROJECT_DIR

  # Render prompt template
  PROMPT=$(render_template "${SCRIPT_DIR}/../prompts/chat.md")

  # Append user message to prompt
  FULL_PROMPT=$(printf '%s\n\nUser message: %s' "$PROMPT" "$USER_INPUT")

  # Call LLM
  start_spinner "Thinking"
  RAW_RESPONSE=$(call_llm "$FULL_PROMPT" 2>/dev/null || true)
  stop_spinner

  if [ -z "$RAW_RESPONSE" ]; then
    echo "Sorry, I couldn't get a response. Please try again."
    append_exchange "$USER_INPUT" "(error: no response)"
    continue
  fi

  # Parse response
  RESPONSE_JSON=$(parse_response "$RAW_RESPONSE" || true)

  if [ -z "$RESPONSE_JSON" ]; then
    # Graceful fallback: print raw response as text
    echo "$RAW_RESPONSE"
    append_exchange "$USER_INPUT" "$RAW_RESPONSE"
    continue
  fi

  ACTION=$(printf '%s' "$RESPONSE_JSON" | jq -r '.action // "answer"')
  PARAMS=$(printf '%s' "$RESPONSE_JSON" | jq -c '.params // {}')
  LLM_RESPONSE=$(printf '%s' "$RESPONSE_JSON" | jq -r '.response // ""')

  # Dispatch action (if not just an answer)
  CMD_OUTPUT=""
  if [ "$ACTION" != "answer" ]; then
    CMD_OUTPUT=$(dispatch "$ACTION" "$PARAMS" 2>&1 || true)
  fi

  # Show LLM response
  if [ -n "$LLM_RESPONSE" ]; then
    echo "$LLM_RESPONSE"
  fi

  # Show command output (if any)
  if [ -n "$CMD_OUTPUT" ]; then
    echo ""
    echo "$CMD_OUTPUT"
  fi

  # Record in history
  HISTORY_ENTRY="[${ACTION}] ${LLM_RESPONSE}"
  append_exchange "$USER_INPUT" "$HISTORY_ENTRY"

  echo ""
done
