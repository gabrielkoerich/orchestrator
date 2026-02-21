#!/usr/bin/env bash
# beads.sh — Beads wrapper functions for orchestrator
# All bd_* functions operate on the current PROJECT_DIR's .beads/ directory.
# Beads is a hidden layer — the user never runs bd directly.
#
# shellcheck disable=SC2155

# Require bd CLI
require_bd() {
  if ! command -v bd >/dev/null 2>&1; then
    log_err "bd (beads) CLI not found. Install: brew install beads"
    return 1
  fi
}

# Run bd in the context of a project directory
# Usage: _bd <project_dir> <bd_args...>
_bd() {
  local dir="$1"; shift
  (cd "$dir" && bd --quiet "$@")
}

# Run bd with JSON output
_bd_json() {
  local dir="$1"; shift
  (cd "$dir" && bd --json --quiet "$@")
}

# ---------------------------------------------------------------------------
# Init & Config
# ---------------------------------------------------------------------------

# Initialize beads in a project directory
# Usage: bd_init [project_dir]
bd_init() {
  local dir="${1:-$PROJECT_DIR}"
  if [ -d "$dir/.beads" ]; then
    return 0  # Already initialized
  fi
  (cd "$dir" && bd init --quiet 2>/dev/null) || true
  # Configure custom statuses matching orchestrator workflow
  _bd "$dir" config set status.custom "new,routed,in_progress,blocked,needs_review,in_review,done"
}

# Check if beads is initialized in a project
# Usage: bd_has_beads [project_dir]
bd_has_beads() {
  local dir="${1:-$PROJECT_DIR}"
  [ -d "$dir/.beads" ]
}

# ---------------------------------------------------------------------------
# Task CRUD
# ---------------------------------------------------------------------------

# Create a new task, returns the task ID
# Usage: bd_create <title> [description] [parent_id]
bd_create() {
  local dir="${PROJECT_DIR:-.}"
  local title="$1"
  local desc="${2:-}"
  local parent="${3:-}"
  local args=(create "$title" --silent)
  [ -n "$desc" ] && args+=(-d "$desc")
  [ -n "$parent" ] && args+=(--parent "$parent")
  _bd "$dir" "${args[@]}"
}

# Show a task as JSON
# Usage: bd_show <task_id>
bd_show() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  _bd_json "$dir" show "$task_id"
}

# Get a single field from a task
# Usage: bd_field <task_id> <field>
# Fields: title, status, priority, assignee, description, type, external-ref
bd_field() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local field="$2"
  _bd_json "$dir" show "$task_id" | jq -r ".${field} // empty"
}

# Get metadata field from a task
# Usage: bd_meta <task_id> <key>
bd_meta() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local key="$2"
  _bd_json "$dir" show "$task_id" | jq -r ".metadata.${key} // empty"
}

# Update a task's status
# Usage: bd_set_status <task_id> <status>
bd_set_status() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local status="$2"
  _bd "$dir" update "$task_id" --status "$status"
}

# Update task fields (generic)
# Usage: bd_update <task_id> [bd update flags...]
bd_update() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"; shift
  _bd "$dir" update "$task_id" "$@"
}

# Set metadata on a task (JSON key-value pairs)
# Usage: bd_set_meta <task_id> <json_string>
# Example: bd_set_meta "bd-abc" '{"agent":"claude","gh_issue":42}'
bd_set_meta() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local meta_json="$2"
  _bd "$dir" update "$task_id" --metadata "$meta_json"
}

# Claim a task atomically (sets assignee + status=in_progress)
# Usage: bd_claim <task_id> [agent_name]
bd_claim() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local agent="${2:-orchestrator}"
  _bd "$dir" update "$task_id" --claim --assignee "$agent" 2>/dev/null
}

# Close a task
# Usage: bd_close <task_id>
bd_close() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  _bd "$dir" close "$task_id"
}

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

# Add a label to a task
# Usage: bd_add_label <task_id> <label>
bd_add_label() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local label="$2"
  _bd "$dir" update "$task_id" --add-label "$label"
}

# Remove a label from a task
# Usage: bd_remove_label <task_id> <label>
bd_remove_label() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local label="$2"
  _bd "$dir" update "$task_id" --remove-label "$label"
}

# Set all labels on a task (replaces existing)
# Usage: bd_set_labels <task_id> <label1,label2,...>
bd_set_labels() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local labels="$2"
  _bd "$dir" update "$task_id" --set-labels "$labels"
}

# ---------------------------------------------------------------------------
# Comments / History
# ---------------------------------------------------------------------------

# Add a comment to a task (replaces db_append_history)
# Usage: bd_comment <task_id> <message>
bd_comment() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local message="$2"
  _bd "$dir" comments add "$task_id" "$message"
}

# List comments on a task as JSON
# Usage: bd_comments <task_id>
bd_comments() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  _bd_json "$dir" comments "$task_id"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# Add a dependency (child depends on parent/blocker)
# Usage: bd_dep_add <blocked_id> <blocker_id>
bd_dep_add() {
  local dir="${PROJECT_DIR:-.}"
  local blocked="$1"
  local blocker="$2"
  _bd "$dir" dep add "$blocked" "$blocker"
}

# List dependencies of a task
# Usage: bd_deps <task_id>
bd_deps() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  _bd_json "$dir" dep list "$task_id"
}

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

# List tasks matching a query (JSON output)
# Usage: bd_list [bd list flags...]
bd_list() {
  local dir="${PROJECT_DIR:-.}"
  _bd_json "$dir" list --limit 0 "$@"
}

# Find ready tasks (unblocked, actionable)
# Usage: bd_ready
bd_ready() {
  local dir="${PROJECT_DIR:-.}"
  # bd query for tasks in new or routed status that aren't blocked
  _bd_json "$dir" query "status=new OR status=routed" --limit 0 2>/dev/null || echo '[]'
}

# Count tasks matching filters
# Usage: bd_count [bd count flags...]
bd_count() {
  local dir="${PROJECT_DIR:-.}"
  _bd "$dir" count "$@"
}

# Count tasks by status (JSON: {"open": 5, "in_progress": 3, ...})
# Usage: bd_status_counts
bd_status_counts() {
  local dir="${PROJECT_DIR:-.}"
  _bd_json "$dir" count --by-status
}

# Find task by external ref (e.g., GitHub issue number)
# Usage: bd_find_by_gh_issue <issue_number>
bd_find_by_gh_issue() {
  local dir="${PROJECT_DIR:-.}"
  local issue_num="$1"
  _bd_json "$dir" list --limit 1 --label "gh:${issue_num}" 2>/dev/null \
    | jq -r '.[0].id // empty'
}

# Find task by metadata field
# Usage: bd_find_by_meta <key> <value>
bd_find_by_meta() {
  local dir="${PROJECT_DIR:-.}"
  local key="$1"
  local value="$2"
  # Search through all tasks for matching metadata
  _bd_json "$dir" list --limit 0 2>/dev/null \
    | jq -r ".[] | select(.metadata.${key} == \"${value}\") | .id" \
    | head -1
}

# Display task tree
# Usage: bd_tree [bd tree flags...]
bd_tree() {
  local dir="${PROJECT_DIR:-.}"
  (cd "$dir" && bd graph "$@" 2>/dev/null) || true
}

# ---------------------------------------------------------------------------
# External Reference Helpers (GitHub issue linking)
# ---------------------------------------------------------------------------

# Link a beads task to a GitHub issue
# Usage: bd_link_gh_issue <task_id> <issue_number>
bd_link_gh_issue() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local issue_num="$2"
  _bd "$dir" update "$task_id" --external-ref "gh-${issue_num}" --add-label "gh:${issue_num}"
}

# Get GitHub issue number from a task
# Usage: bd_gh_issue <task_id>
bd_gh_issue() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local ext_ref
  ext_ref=$(_bd_json "$dir" show "$task_id" | jq -r '.external_ref // empty')
  # Extract number from "gh-42"
  echo "${ext_ref#gh-}"
}

# ---------------------------------------------------------------------------
# Project Registry
# ---------------------------------------------------------------------------

# List all registered project paths
# Usage: bd_project_paths
bd_project_paths() {
  local projects_file="${ORCH_HOME:-$HOME/.orchestrator}/projects.yml"
  if [ ! -f "$projects_file" ]; then
    # Fallback: just the current PROJECT_DIR
    echo "${PROJECT_DIR:-.}"
    return
  fi
  yq -r '.projects[].path' "$projects_file" 2>/dev/null
}

# Get project config value
# Usage: bd_project_config <project_path> <yq_expr>
bd_project_config() {
  local project_dir="$1"
  local expr="$2"
  local config_file="${project_dir}/.orchestrator/config.yml"
  if [ -f "$config_file" ]; then
    yq -r "$expr" "$config_file" 2>/dev/null
  fi
}

# Get project repo (owner/repo)
# Usage: bd_project_repo [project_dir]
bd_project_repo() {
  local dir="${1:-$PROJECT_DIR}"
  # Try project-local config first
  local repo
  repo=$(bd_project_config "$dir" '.repo // ""')
  if [ -n "$repo" ] && [ "$repo" != "null" ]; then
    echo "$repo"
    return
  fi
  # Fallback to global config
  config_get '.gh.repo // ""'
}

# ---------------------------------------------------------------------------
# Agent Helpers
# ---------------------------------------------------------------------------

# Store agent response as metadata + comment
# Usage: bd_store_agent_response <task_id> <status> <summary> [metadata_json]
bd_store_agent_response() {
  local dir="${PROJECT_DIR:-.}"
  local task_id="$1"
  local status="$2"
  local summary="$3"
  local meta="${4:-}"

  bd_set_status "$task_id" "$status"

  if [ -n "$summary" ]; then
    bd_comment "$task_id" "$summary"
  fi

  if [ -n "$meta" ]; then
    bd_set_meta "$task_id" "$meta"
  fi
}
