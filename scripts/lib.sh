#!/usr/bin/env bash
set -euo pipefail

TASKS_PATH=${TASKS_PATH:-tasks.yml}

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

  local esc_id esc_title esc_labels esc_body
  esc_id=$(escape_sed "$task_id")
  esc_title=$(escape_sed "$task_title")
  esc_labels=$(escape_sed "$task_labels")
  esc_body=$(escape_sed "$task_body")

  sed \
    -e "s/{{TASK_ID}}/${esc_id}/g" \
    -e "s/{{TASK_TITLE}}/${esc_title}/g" \
    -e "s/{{TASK_LABELS}}/${esc_labels}/g" \
    -e "s/{{TASK_BODY}}/${esc_body}/g" \
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
