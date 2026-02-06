#!/usr/bin/env bash
set -euo pipefail

TASKS_PATH=${TASKS_PATH:-tasks.yml}
LOCK_PATH=${LOCK_PATH:-"${TASKS_PATH}.lock"}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
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

  local esc_id esc_title esc_labels esc_body esc_profile
  esc_id=$(escape_sed "$task_id")
  esc_title=$(escape_sed "$task_title")
  esc_labels=$(escape_sed "$task_labels")
  esc_body=$(escape_sed "$task_body")
  esc_profile=$(escape_sed "$agent_profile_json")

  sed \
    -e "s/{{TASK_ID}}/${esc_id}/g" \
    -e "s/{{TASK_TITLE}}/${esc_title}/g" \
    -e "s/{{TASK_LABELS}}/${esc_labels}/g" \
    -e "s/{{TASK_BODY}}/${esc_body}/g" \
    -e "s/{{AGENT_PROFILE_JSON}}/${esc_profile}/g" \
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
    cat > "$TASKS_PATH" <<'YAML'
version: 1
router:
  agent: codex
agents:
  - id: codex
    description: General-purpose coding agent (CLI: codex).
  - id: claude
    description: General-purpose reasoning agent (CLI: claude).
tasks: []
YAML
  fi
}

acquire_lock() {
  local wait_seconds=${LOCK_WAIT_SECONDS:-5}
  local start
  start=$(date +%s)

  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
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

with_lock() {
  acquire_lock
  "$@"
  local status=$?
  release_lock
  return "$status"
}
