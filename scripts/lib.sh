#!/usr/bin/env bash
set -euo pipefail

TASKS_PATH=${TASKS_PATH:-tasks.yml}
LOCK_PATH=${LOCK_PATH:-"${TASKS_PATH}.lock"}
CONTEXTS_DIR=${CONTEXTS_DIR:-"contexts"}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date -u +"%s"
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

  sed \
    -e "s/{{TASK_ID}}/${esc_id}/g" \
    -e "s/{{TASK_TITLE}}/${esc_title}/g" \
    -e "s/{{TASK_LABELS}}/${esc_labels}/g" \
    -e "s/{{TASK_BODY}}/${esc_body}/g" \
    -e "s/{{AGENT_PROFILE_JSON}}/${esc_profile}/g" \
    -e "s/{{TASK_SUMMARY}}/${esc_summary}/g" \
    -e "s/{{TASK_FILES_CHANGED}}/${esc_files}/g" \
    -e "s/{{TASK_CONTEXT}}/${esc_context}/g" \
    "$template_path"
}

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required but not found in PATH." >&2
    exit 1
  fi
}

init_tasks_file() {
  if [ ! -f "$TASKS_PATH" ]; then
    if [ -f "tasks.example.yml" ]; then
      cp "tasks.example.yml" "$TASKS_PATH"
    else
      cat > "$TASKS_PATH" <<'YAML'
version: 1
router:
  agent: codex
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

acquire_lock() {
  local wait_seconds=${LOCK_WAIT_SECONDS:-5}
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
      exit 1
    fi
    sleep 0.05
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
  "$@"
}
