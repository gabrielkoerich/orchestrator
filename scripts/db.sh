#!/usr/bin/env bash
# SQLite database wrapper for orchestrator.
# Sourced by lib.sh — provides task/job CRUD that replaces yq-based YAML operations.
# All functions are prefixed with db_ to avoid collision during the transition period.

DB_PATH="${DB_PATH:-${ORCH_HOME}/orchestrator.db}"
SCHEMA_PATH="${SCHEMA_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schema.sql}"

# ============================================================
# Core database helpers
# ============================================================

# Check if SQLite database exists and is initialized
db_exists() {
  [ -f "$DB_PATH" ] && sqlite3 "$DB_PATH" "SELECT 1 FROM tasks LIMIT 0" 2>/dev/null
}

# Initialize database from schema if it doesn't exist
db_init() {
  if [ ! -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" < "$SCHEMA_PATH"
  fi
}

# Run a query, tab-separated output (default)
db() {
  sqlite3 -separator $'\t' "$DB_PATH" "$@"
}

# Run a query, JSON output
db_json() {
  sqlite3 -json "$DB_PATH" "$@"
}

# Run a query expecting a single scalar value
db_scalar() {
  sqlite3 "$DB_PATH" "$@"
}

# Escape a string for SQL single quotes (double up single quotes)
sql_escape() {
  printf '%s' "${1:-}" | sed "s/'/''/g"
}

# ============================================================
# Task CRUD
# ============================================================

# Read a single field from a task.
# Usage: db_task_field <id> <column>
# Example: db_task_field 3 status  →  "done"
db_task_field() {
  local id="$1" field="$2"
  db_scalar "SELECT \`$field\` FROM tasks WHERE id = $id;"
}

# Update a single field on a task (also bumps updated_at).
# Usage: db_task_set <id> <column> <value>
# Example: db_task_set 3 status "done"
db_task_set() {
  local id="$1" field="$2" value="$3"
  local escaped
  escaped=$(sql_escape "$value")
  db "UPDATE tasks SET \`$field\` = '$escaped', updated_at = datetime('now') WHERE id = $id;"
}

# Atomically claim a task — returns 1 if someone else already claimed it.
# This eliminates the YAML race condition where two poll cycles pick the same task.
# Usage: db_task_claim <id> <from_status> <to_status>
db_task_claim() {
  local id="$1" from_status="$2" to_status="$3"
  db "UPDATE tasks SET status = '$to_status', updated_at = datetime('now') WHERE id = $id AND status = '$from_status';"
  local changed
  changed=$(db_scalar "SELECT changes();")
  [ "$changed" -gt 0 ]
}

# Count tasks, optionally filtered by status and/or dir.
# Usage: db_task_count [status] [dir]
db_task_count() {
  local _tc_status="${1:-}" _tc_dir="${2:-}"
  local where="1=1"
  [ -n "$_tc_status" ] && where="$where AND status = '$(sql_escape "$_tc_status")'"
  [ -n "$_tc_dir" ] && where="$where AND (dir = '$(sql_escape "$_tc_dir")' OR dir IS NULL OR dir = '')"
  db_scalar "SELECT COUNT(*) FROM tasks WHERE $where;"
}

# List tasks as TSV rows.
# Usage: db_task_list <columns> [where_clause] [order]
# Example: db_task_list "id, status, title" "status = 'new'" "id ASC"
db_task_list() {
  local columns="${1:-id, status, title}" where="${2:-1=1}" order="${3:-id ASC}"
  db "SELECT $columns FROM tasks WHERE $where ORDER BY $order;"
}

# Get task IDs matching a status, excluding tasks with a specific label.
# Usage: db_task_ids_by_status <status> [exclude_label]
# Example: db_task_ids_by_status "new" "no-agent"
db_task_ids_by_status() {
  local status="$1" exclude_label="${2:-}"
  if [ -n "$exclude_label" ]; then
    db_scalar "SELECT t.id FROM tasks t
      WHERE t.status = '$status'
        AND t.id NOT IN (SELECT task_id FROM task_labels WHERE label = '$(sql_escape "$exclude_label")')
      ORDER BY t.id;"
  else
    db_scalar "SELECT id FROM tasks WHERE status = '$status' ORDER BY id;"
  fi
}

# Get next available ID.
db_next_id() {
  local max
  max=$(db_scalar "SELECT COALESCE(MAX(id), 0) FROM tasks;")
  echo $((max + 1))
}

# Create a new task. Returns the new task ID.
# Usage: db_create_task <title> [body] [dir] [labels_csv] [parent_id] [agent]
db_create_task() {
  local title="$1" body="${2:-}" dir="${3:-${PROJECT_DIR:-}}"
  local labels_csv="${4:-}" parent_id="${5:-}" agent="${6:-}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local parent_val="NULL"
  [ -n "$parent_id" ] && parent_val="$parent_id"

  local agent_val="NULL"
  [ -n "$agent" ] && agent_val="'$(sql_escape "$agent")'"

  local new_id
  new_id=$(db_scalar "INSERT INTO tasks (title, body, dir, status, parent_id, agent, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
    VALUES ('$(sql_escape "$title")', '$(sql_escape "$body")', '$(sql_escape "$dir")', 'new', $parent_val, $agent_val, 0, 0, 0, 0, '$now', '$now')
    RETURNING id;")

  # Insert labels
  if [ -n "$labels_csv" ]; then
    printf '%s\n' "$labels_csv" | tr ',' '\n' | while IFS= read -r label; do
      label=$(printf '%s' "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$label" ] && continue
      db "INSERT OR IGNORE INTO task_labels (task_id, label) VALUES ($new_id, '$(sql_escape "$label")');"
    done
  fi

  # Link parent → child
  if [ -n "$parent_id" ]; then
    db "INSERT OR IGNORE INTO task_children (parent_id, child_id) VALUES ($parent_id, $new_id);"
  fi

  echo "$new_id"
}

# ============================================================
# Task array fields (labels, history, files, children, etc.)
# ============================================================

# Append a history entry.
# Usage: db_append_history <task_id> <status> <note>
db_append_history() {
  local task_id="$1" _ah_status="$2" note="$3"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  db "INSERT INTO task_history (task_id, ts, status, note)
    VALUES ($task_id, '$now', '$(sql_escape "$_ah_status")', '$(sql_escape "$note")');"
}

# Get task history as TSV (ts, status, note).
db_task_history() {
  local task_id="$1"
  db "SELECT ts, status, note FROM task_history WHERE task_id = $task_id ORDER BY id;"
}

# Get task labels as newline-separated list.
db_task_labels() {
  local task_id="$1"
  db_scalar "SELECT label FROM task_labels WHERE task_id = $task_id ORDER BY label;"
}

# Get task labels as comma-separated string.
db_task_labels_csv() {
  local task_id="$1"
  db_scalar "SELECT GROUP_CONCAT(label, ',') FROM task_labels WHERE task_id = $task_id;"
}

# Set labels for a task (replaces existing).
# Usage: db_set_labels <task_id> <labels_csv>
db_set_labels() {
  local task_id="$1" labels_csv="$2"
  db "DELETE FROM task_labels WHERE task_id = $task_id;"
  if [ -n "$labels_csv" ]; then
    printf '%s\n' "$labels_csv" | tr ',' '\n' | while IFS= read -r label; do
      label=$(printf '%s' "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$label" ] && continue
      db "INSERT OR IGNORE INTO task_labels (task_id, label) VALUES ($task_id, '$(sql_escape "$label")');"
    done
  fi
}

# Add a label to a task.
db_add_label() {
  local task_id="$1" label="$2"
  db "INSERT OR IGNORE INTO task_labels (task_id, label) VALUES ($task_id, '$(sql_escape "$label")');"
}

# Remove a label from a task.
db_remove_label() {
  local task_id="$1" label="$2"
  db "DELETE FROM task_labels WHERE task_id = $task_id AND label = '$(sql_escape "$label")';"
}

# Set files_changed for a task (replaces existing).
db_set_files() {
  local task_id="$1" files_csv="$2"
  db "DELETE FROM task_files WHERE task_id = $task_id;"
  if [ -n "$files_csv" ]; then
    printf '%s\n' "$files_csv" | tr ',' '\n' | while IFS= read -r f; do
      f=$(printf '%s' "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$f" ] && continue
      db "INSERT OR IGNORE INTO task_files (task_id, file_path) VALUES ($task_id, '$(sql_escape "$f")');"
    done
  fi
}

# Get files_changed as comma-separated string.
db_task_files_csv() {
  local task_id="$1"
  db_scalar "SELECT GROUP_CONCAT(file_path, ', ') FROM task_files WHERE task_id = $task_id;"
}

# Get child task IDs.
db_task_children() {
  local parent_id="$1"
  db_scalar "SELECT child_id FROM task_children WHERE parent_id = $parent_id ORDER BY child_id;"
}

# Add a child to a parent task.
db_add_child() {
  local parent_id="$1" child_id="$2"
  db "INSERT OR IGNORE INTO task_children (parent_id, child_id) VALUES ($parent_id, $child_id);"
}

# Set accomplished items (replaces existing).
db_set_accomplished() {
  local task_id="$1"
  shift
  db "DELETE FROM task_accomplished WHERE task_id = $task_id;"
  for item in "$@"; do
    [ -z "$item" ] && continue
    db "INSERT INTO task_accomplished (task_id, item) VALUES ($task_id, '$(sql_escape "$item")');"
  done
}

# Set remaining items.
db_set_remaining() {
  local task_id="$1"
  shift
  db "DELETE FROM task_remaining WHERE task_id = $task_id;"
  for item in "$@"; do
    [ -z "$item" ] && continue
    db "INSERT INTO task_remaining (task_id, item) VALUES ($task_id, '$(sql_escape "$item")');"
  done
}

# Set blockers.
db_set_blockers() {
  local task_id="$1"
  shift
  db "DELETE FROM task_blockers WHERE task_id = $task_id;"
  for item in "$@"; do
    [ -z "$item" ] && continue
    db "INSERT INTO task_blockers (task_id, item) VALUES ($task_id, '$(sql_escape "$item")');"
  done
}

# Set selected_skills.
db_set_selected_skills() {
  local task_id="$1" skills_csv="$2"
  db "DELETE FROM task_selected_skills WHERE task_id = $task_id;"
  if [ -n "$skills_csv" ]; then
    printf '%s\n' "$skills_csv" | tr ',' '\n' | while IFS= read -r skill; do
      skill=$(printf '%s' "$skill" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$skill" ] && continue
      db "INSERT OR IGNORE INTO task_selected_skills (task_id, skill) VALUES ($task_id, '$(sql_escape "$skill")');"
    done
  fi
}

# ============================================================
# Task bulk update (multi-field)
# ============================================================

# Update multiple fields on a task at once.
# Usage: db_task_update <id> <field1>=<value1> [field2=value2] ...
# Example: db_task_update 3 status=done summary="All tests pass" agent=claude
db_task_update() {
  local id="$1"
  shift
  local sets=""
  for pair in "$@"; do
    local field="${pair%%=*}"
    local value="${pair#*=}"
    if [ -n "$sets" ]; then
      sets="$sets, "
    fi
    if [ "$value" = "NULL" ] || [ "$value" = "null" ]; then
      sets="$sets\`$field\` = NULL"
    else
      sets="$sets\`$field\` = '$(sql_escape "$value")'"
    fi
  done
  if [ -n "$sets" ]; then
    db "UPDATE tasks SET $sets, updated_at = datetime('now') WHERE id = $id;"
  fi
}

# ============================================================
# Task query helpers (match common yq patterns)
# ============================================================

# Get a full task as JSON (for passing to agents or gh_push).
db_task_json() {
  local id="$1"
  local task_json labels_json history_json files_json children_json
  local accomplished_json remaining_json blockers_json skills_json

  task_json=$(db_json "SELECT * FROM tasks WHERE id = $id;")
  labels_json=$(db_json "SELECT label FROM task_labels WHERE task_id = $id ORDER BY label;")
  history_json=$(db_json "SELECT ts, status, note FROM task_history WHERE task_id = $id ORDER BY id;")
  files_json=$(db_json "SELECT file_path FROM task_files WHERE task_id = $id;")
  children_json=$(db_json "SELECT child_id FROM task_children WHERE parent_id = $id ORDER BY child_id;")
  accomplished_json=$(db_json "SELECT item FROM task_accomplished WHERE task_id = $id;")
  remaining_json=$(db_json "SELECT item FROM task_remaining WHERE task_id = $id;")
  blockers_json=$(db_json "SELECT item FROM task_blockers WHERE task_id = $id;")
  skills_json=$(db_json "SELECT skill FROM task_selected_skills WHERE task_id = $id;")

  # Merge into a single JSON object using jq
  printf '%s' "$task_json" | jq --argjson labels "$(printf '%s' "$labels_json" | jq '[.[].label] // []' 2>/dev/null || echo '[]')" \
    --argjson history "$(printf '%s' "$history_json" | jq '. // []' 2>/dev/null || echo '[]')" \
    --argjson files "$(printf '%s' "$files_json" | jq '[.[].file_path] // []' 2>/dev/null || echo '[]')" \
    --argjson children "$(printf '%s' "$children_json" | jq '[.[].child_id] // []' 2>/dev/null || echo '[]')" \
    --argjson accomplished "$(printf '%s' "$accomplished_json" | jq '[.[].item] // []' 2>/dev/null || echo '[]')" \
    --argjson remaining "$(printf '%s' "$remaining_json" | jq '[.[].item] // []' 2>/dev/null || echo '[]')" \
    --argjson blockers "$(printf '%s' "$blockers_json" | jq '[.[].item] // []' 2>/dev/null || echo '[]')" \
    --argjson selected_skills "$(printf '%s' "$skills_json" | jq '[.[].skill] // []' 2>/dev/null || echo '[]')" \
    '.[0] + {labels: $labels, history: $history, files_changed: $files, children: $children, accomplished: $accomplished, remaining: $remaining, blockers: $blockers, selected_skills: $selected_skills}'
}

# Build env-var export block for a task (used by run_task.sh prompt builder).
# Returns lines like: export TASK_ID=3; export TASK_TITLE="Fix bug"; ...
db_task_env_exports() {
  local id="$1"
  db "SELECT
    'export TASK_ID=' || id ||
    char(10) || 'export TASK_TITLE=' || quote(title) ||
    char(10) || 'export TASK_BODY=' || quote(COALESCE(body, '')) ||
    char(10) || 'export TASK_STATUS=' || quote(status) ||
    char(10) || 'export TASK_AGENT=' || quote(COALESCE(agent, '')) ||
    char(10) || 'export AGENT_MODEL=' || quote(COALESCE(agent_model, '')) ||
    char(10) || 'export TASK_COMPLEXITY=' || quote(COALESCE(complexity, 'medium')) ||
    char(10) || 'export TASK_SUMMARY=' || quote(COALESCE(summary, '')) ||
    char(10) || 'export TASK_DIR=' || quote(COALESCE(dir, ''))
    FROM tasks WHERE id = $id;"
}

# ============================================================
# Job CRUD
# ============================================================

# Create a job.
db_create_job() {
  local id="$1" title="$2" schedule="$3" type="${4:-task}"
  local body="${5:-}" labels="${6:-}" agent="${7:-}" dir="${8:-}" command="${9:-}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  db "INSERT INTO jobs (id, title, schedule, type, command, body, labels, agent, dir, enabled, created_at)
    VALUES ('$(sql_escape "$id")', '$(sql_escape "$title")', '$(sql_escape "$schedule")', '$(sql_escape "$type")',
            $([ -n "$command" ] && echo "'$(sql_escape "$command")'" || echo "NULL"),
            '$(sql_escape "$body")', '$(sql_escape "$labels")', $([ -n "$agent" ] && echo "'$(sql_escape "$agent")'" || echo "NULL"),
            '$(sql_escape "$dir")', 1, '$now');"
}

# Get a job field.
db_job_field() {
  local id="$1" field="$2"
  db_scalar "SELECT \`$field\` FROM jobs WHERE id = '$(sql_escape "$id")';"
}

# Update a job field.
db_job_set() {
  local id="$1" field="$2" value="$3"
  db "UPDATE jobs SET \`$field\` = '$(sql_escape "$value")' WHERE id = '$(sql_escape "$id")';"
}

# List all jobs as TSV.
db_job_list() {
  db "SELECT id, title, schedule, type, enabled, active_task_id, last_run FROM jobs ORDER BY id;"
}

# Delete a job.
db_job_delete() {
  local id="$1"
  db "DELETE FROM jobs WHERE id = '$(sql_escape "$id")';"
}

# ============================================================
# Locking (SQLite replaces file-based locking)
# ============================================================

# With SQLite WAL mode + busy_timeout, we don't need external locking.
# These are compatibility shims during the transition.
db_acquire_lock() { :; }   # no-op — SQLite handles concurrency
db_release_lock() { :; }   # no-op
db_with_lock() { "$@"; }   # just run the command directly

# ============================================================
# Export for YAML compatibility (transition period)
# ============================================================

# Export all tasks to YAML format (for backward compatibility during migration).
db_export_tasks_yaml() {
  local output="${1:-/dev/stdout}"
  local tasks_json
  tasks_json=$(db_json "SELECT * FROM tasks ORDER BY id;")
  # Convert to YAML via yq
  printf '{"tasks": %s}' "$tasks_json" | yq -P -o=yaml > "$output"
}
