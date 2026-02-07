#!/usr/bin/env bash
set -euo pipefail

TASKS_PATH=${TASKS_PATH:-tasks.yml}
LOCK_PATH=${LOCK_PATH:-"${TASKS_PATH}.lock"}
CONTEXTS_DIR=${CONTEXTS_DIR:-"contexts"}
CONFIG_PATH=${CONFIG_PATH:-"config.yml"}
STATE_DIR=${STATE_DIR:-".orchestrator"}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date -u +"%s"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

gh_backoff_path() {
  echo "${GH_BACKOFF_PATH:-${STATE_DIR}/gh_backoff}"
}

gh_backoff_reset() {
  rm -f "$(gh_backoff_path)" 2>/dev/null || true
}

gh_backoff_read() {
  local path
  path=$(gh_backoff_path)
  if [ ! -f "$path" ]; then
    echo "0 0"
    return 0
  fi
  local until delay
  until=$(awk -F= '/^until=/{print $2}' "$path" 2>/dev/null | tail -n1)
  delay=$(awk -F= '/^delay=/{print $2}' "$path" 2>/dev/null | tail -n1)
  until=${until:-0}
  delay=${delay:-0}
  echo "$until $delay"
}

gh_backoff_active() {
  local now until delay
  read -r until delay < <(gh_backoff_read)
  now=$(now_epoch)
  if [ "$until" -gt "$now" ]; then
    echo $((until - now))
    return 0
  fi
  return 1
}

gh_backoff_set() {
  local delay="$1"
  local reason="${2:-rate_limit}"
  ensure_state_dir
  local until
  until=$(( $(now_epoch) + delay ))
  {
    echo "until=$until"
    echo "delay=$delay"
    echo "reason=$reason"
  } > "$(gh_backoff_path)"
}

gh_backoff_next_delay() {
  local base="${1:-30}"
  local max="${2:-900}"
  local until last_delay
  read -r until last_delay < <(gh_backoff_read)
  local next
  if [ "${last_delay:-0}" -gt 0 ]; then
    next=$((last_delay * 2))
  else
    next=$base
  fi
  if [ "$next" -gt "$max" ]; then
    next=$max
  fi
  echo "$next"
}

gh_api() {
  local mode=${GH_BACKOFF_MODE:-wait}
  local base=${GH_BACKOFF_BASE_SECONDS:-30}
  local max=${GH_BACKOFF_MAX_SECONDS:-900}
  local errexit_enabled=0
  if [[ $- == *e* ]]; then
    errexit_enabled=1
  fi

  local remaining
  if remaining=$(gh_backoff_active); then
    if [ "$mode" = "wait" ]; then
      sleep "$remaining"
    else
      echo "[gh] backoff active for ${remaining}s; skipping request." >&2
      return 75
    fi
  fi

  local out err rc
  out=$(mktemp)
  err=$(mktemp)
  set +e
  command gh api "$@" >"$out" 2>"$err"
  rc=$?
  if [ "$errexit_enabled" -eq 1 ]; then
    set -e
  else
    set +e
  fi

  if [ "$rc" -eq 0 ]; then
    gh_backoff_reset
    cat "$out"
    rm -f "$out" "$err"
    return 0
  fi

  if grep -qiE "secondary rate limit|rate limit|API rate limit|abuse detection|HTTP 403" "$err"; then
    local delay
    delay=$(gh_backoff_next_delay "$base" "$max")
    gh_backoff_set "$delay" "rate_limit"
    echo "[gh] rate limit detected; backing off for ${delay}s." >&2
    if [ "$mode" = "wait" ]; then
      sleep "$delay"
      set +e
      command gh api "$@" >"$out" 2>"$err"
      rc=$?
      if [ "$errexit_enabled" -eq 1 ]; then
        set -e
      else
        set +e
      fi
      if [ "$rc" -eq 0 ]; then
        gh_backoff_reset
        cat "$out"
        rm -f "$out" "$err"
        return 0
      fi
    else
      rm -f "$out" "$err"
      return 75
    fi
  fi

  cat "$err" >&2
  rm -f "$out" "$err"
  return "$rc"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

render_template() {
  local template_path="$1"
  local task_id="$2"
  local task_title="$3"
  local task_labels="$4"
  local task_body="$5"
  local agent_profile_json="${6:-{}}"
  local task_summary="${7:-}"
  local task_files_changed="${8:-}"
  local task_context="${9:-}"

  local esc_id esc_title esc_labels esc_body esc_profile esc_summary esc_files esc_context
  esc_id=$(escape_sed "$task_id")
  esc_title=$(escape_sed "$task_title")
  esc_labels=$(escape_sed "$task_labels")
  esc_body=$(escape_sed "$task_body")
  esc_profile=$(escape_sed "$agent_profile_json")
  esc_summary=$(escape_sed "$task_summary")
  esc_files=$(escape_sed "$task_files_changed")
  esc_context=$(escape_sed "$task_context")

  if command -v python3 >/dev/null 2>&1; then
    TASK_ID="$task_id" \
    TASK_TITLE="$task_title" \
    TASK_LABELS="$task_labels" \
    TASK_BODY="$task_body" \
    AGENT_PROFILE_JSON="$agent_profile_json" \
    TASK_SUMMARY="$task_summary" \
    TASK_FILES_CHANGED="$task_files_changed" \
    TASK_CONTEXT="$task_context" \
    python3 - "$template_path" <<'PY'
import os
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

repl = {
    "{{TASK_ID}}": os.environ.get("TASK_ID", ""),
    "{{TASK_TITLE}}": os.environ.get("TASK_TITLE", ""),
    "{{TASK_LABELS}}": os.environ.get("TASK_LABELS", ""),
    "{{TASK_BODY}}": os.environ.get("TASK_BODY", ""),
    "{{AGENT_PROFILE_JSON}}": os.environ.get("AGENT_PROFILE_JSON", ""),
    "{{TASK_SUMMARY}}": os.environ.get("TASK_SUMMARY", ""),
    "{{TASK_FILES_CHANGED}}": os.environ.get("TASK_FILES_CHANGED", ""),
    "{{TASK_CONTEXT}}": os.environ.get("TASK_CONTEXT", ""),
    "{{SKILLS_CATALOG}}": os.environ.get("TASK_CONTEXT", ""),
  }

for key, val in repl.items():
    data = data.replace(key, val)

sys.stdout.write(data)
PY
    return 0
  fi

  sed \
    -e "s/{{TASK_ID}}/${esc_id}/g" \
    -e "s/{{TASK_TITLE}}/${esc_title}/g" \
    -e "s/{{TASK_LABELS}}/${esc_labels}/g" \
    -e "s/{{TASK_BODY}}/${esc_body}/g" \
    -e "s/{{AGENT_PROFILE_JSON}}/${esc_profile}/g" \
    -e "s/{{TASK_SUMMARY}}/${esc_summary}/g" \
    -e "s/{{TASK_FILES_CHANGED}}/${esc_files}/g" \
    -e "s/{{TASK_CONTEXT}}/${esc_context}/g" \
    -e "s/{{SKILLS_CATALOG}}/${esc_context}/g" \
    "$template_path"
}

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required but not found in PATH." >&2
    exit 1
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not found in PATH." >&2
    exit 1
  fi
}

normalize_json_response() {
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    RAW_RESPONSE="$raw" python3 "${script_dir}/normalize_json.py"
    return $?
  fi

  return 1
}

init_tasks_file() {
  if [ ! -f "$TASKS_PATH" ]; then
    if [ -f "tasks.example.yml" ]; then
      cp "tasks.example.yml" "$TASKS_PATH"
    else
      cat > "$TASKS_PATH" <<'YAML'
version: 1
agents:
  - id: codex
    description: General-purpose coding agent.
  - id: claude
    description: General-purpose reasoning agent.
tasks: []
YAML
    fi
  fi
}

init_config_file() {
  if [ ! -f "$CONFIG_PATH" ]; then
    if [ -f "config.example.yml" ]; then
      cp "config.example.yml" "$CONFIG_PATH"
    else
      cat > "$CONFIG_PATH" <<'YAML'
workflow:
  auto_close: true
  review_owner: ""
gh:
  repo: ""
  sync_label: ""
  project_id: ""
  project_status_field_id: ""
  project_status_map:
    backlog: ""
    in_progress: ""
    review: ""
    done: ""
YAML
    fi
  fi
}

config_get() {
  local key="$1"
  if [ -f "$CONFIG_PATH" ]; then
    yq -r "$key" "$CONFIG_PATH"
  else
    echo ""
  fi
}

acquire_lock() {
  local wait_seconds=${LOCK_WAIT_SECONDS:-20}
  local start
  start=$(date +%s)

  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if lock_is_stale "$LOCK_PATH"; then
      rmdir "$LOCK_PATH" 2>/dev/null || true
      continue
    fi
    local now
    now=$(date +%s)
    if [ $((now - start)) -ge "$wait_seconds" ]; then
      echo "Failed to acquire lock: $LOCK_PATH" >&2
      echo "Tip: if no orchestrator is running, remove stale locks with 'just unlock'." >&2
      exit 1
    fi
    sleep 0.1
  done
}

release_lock() {
  rmdir "$LOCK_PATH" 2>/dev/null || true
}

lock_mtime() {
  local path="$1"
  if command -v stat >/dev/null 2>&1; then
    if stat -f %m "$path" >/dev/null 2>&1; then
      stat -f %m "$path"
      return 0
    fi
    if stat -c %Y "$path" >/dev/null 2>&1; then
      stat -c %Y "$path"
      return 0
    fi
  fi
  echo 0
}

lock_is_stale() {
  local path="$1"
  local stale_seconds=${LOCK_STALE_SECONDS:-600}
  local mtime
  mtime=$(lock_mtime "$path")
  if [ "$mtime" -eq 0 ]; then
    return 1
  fi
  local now
  now=$(date +%s)
  if [ $((now - mtime)) -ge "$stale_seconds" ]; then
    return 0
  fi
  return 1
}

with_lock() {
  acquire_lock
  "$@"
  local status=$?
  release_lock
  return "$status"
}

append_history() {
  local task_id="$1"
  local status="$2"
  local note="$3"
  local ts
  ts=$(now_iso)
  export ts status note

  with_lock yq -i \
    "(.tasks[] | select(.id == $task_id) | .history) += [{\"ts\": env(ts), \"status\": env(status), \"note\": env(note)}]" \
    "$TASKS_PATH"
}

load_task_context() {
  local task_id="$1"
  local role="$2"
  local task_ctx_file="${CONTEXTS_DIR}/task-${task_id}.md"
  local profile_ctx_file="${CONTEXTS_DIR}/profile-${role}.md"

  local out=""
  if [ -f "$profile_ctx_file" ]; then
    out+="[profile:${role}]\n"
    out+="$(cat "$profile_ctx_file")\n\n"
  fi
  if [ -f "$task_ctx_file" ]; then
    out+="[task:${task_id}]\n"
    out+="$(cat "$task_ctx_file")\n"
  fi
  printf '%b' "$out"
}

append_task_context() {
  local task_id="$1"
  local content="$2"
  local task_ctx_file="${CONTEXTS_DIR}/task-${task_id}.md"

  mkdir -p "$CONTEXTS_DIR"
  printf '%s\n' "$content" >> "$task_ctx_file"
}

retry_delay_seconds() {
  local attempts=$1
  local base=${RETRY_BASE_SECONDS:-60}
  local max=${RETRY_MAX_SECONDS:-3600}
  local exp=$((attempts - 1))
  local delay=$base
  if [ "$exp" -gt 0 ]; then
    delay=$((base * (2 ** exp)))
  fi
  if [ "$delay" -gt "$max" ]; then
    delay=$max
  fi
  echo "$delay"
}

run_with_timeout() {
  local timeout_seconds=${AGENT_TIMEOUT_SECONDS:-900}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_seconds" "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
cmd = sys.argv[2:]

try:
    result = subprocess.run(cmd, timeout=timeout_seconds)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
    return $?
  fi
  "$@"
}
