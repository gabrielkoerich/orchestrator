#!/usr/bin/env bash
# One-time migration: tasks.yml + jobs.yml → SQLite database
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
require_yq

DB_PATH="${DB_PATH:-${ORCH_HOME}/orchestrator.db}"
SCHEMA_PATH="${SCHEMA_PATH:-${SCRIPT_DIR}/schema.sql}"

if [ -f "$DB_PATH" ]; then
  echo "Database already exists at $DB_PATH"
  echo "To re-migrate, remove it first: rm $DB_PATH"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required but not found in PATH." >&2
  exit 1
fi

echo "==> Creating database at $DB_PATH"
sqlite3 "$DB_PATH" < "$SCHEMA_PATH"

# ============================================================
# Migrate tasks
# ============================================================
TASKS_FILE="${TASKS_PATH:-${ORCH_HOME}/tasks.yml}"
if [ -f "$TASKS_FILE" ]; then
  TASK_COUNT=$(yq -r '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo "0")
  echo "==> Migrating $TASK_COUNT tasks from $TASKS_FILE"

  for i in $(seq 0 $((TASK_COUNT - 1))); do
    # Extract scalar fields
    ID=$(yq -r ".tasks[$i].id" "$TASKS_FILE")
    TITLE=$(yq -r ".tasks[$i].title // \"\"" "$TASKS_FILE")
    BODY=$(yq -r ".tasks[$i].body // \"\"" "$TASKS_FILE")
    STATUS=$(yq -r ".tasks[$i].status // \"new\"" "$TASKS_FILE")
    AGENT=$(yq -r ".tasks[$i].agent // \"\"" "$TASKS_FILE")
    AGENT_MODEL=$(yq -r ".tasks[$i].agent_model // \"\"" "$TASKS_FILE")
    AGENT_PROFILE=$(yq -r ".tasks[$i].agent_profile // \"\"" "$TASKS_FILE")
    COMPLEXITY=$(yq -r ".tasks[$i].complexity // \"\"" "$TASKS_FILE")
    PARENT_ID=$(yq -r ".tasks[$i].parent_id // \"\"" "$TASKS_FILE")
    ROUTE_REASON=$(yq -r ".tasks[$i].route_reason // \"\"" "$TASKS_FILE")
    ROUTE_WARNING=$(yq -r ".tasks[$i].route_warning // \"\"" "$TASKS_FILE")
    SUMMARY=$(yq -r ".tasks[$i].summary // \"\"" "$TASKS_FILE")
    REASON=$(yq -r ".tasks[$i].reason // \"\"" "$TASKS_FILE")
    NEEDS_HELP=$(yq -r ".tasks[$i].needs_help // false" "$TASKS_FILE")
    ATTEMPTS=$(yq -r ".tasks[$i].attempts // 0" "$TASKS_FILE")
    LAST_ERROR=$(yq -r ".tasks[$i].last_error // \"\"" "$TASKS_FILE")
    PROMPT_HASH=$(yq -r ".tasks[$i].prompt_hash // \"\"" "$TASKS_FILE")
    LAST_COMMENT_HASH=$(yq -r ".tasks[$i].last_comment_hash // \"\"" "$TASKS_FILE")
    RETRY_AT=$(yq -r ".tasks[$i].retry_at // \"\"" "$TASKS_FILE")
    REVIEW_DECISION=$(yq -r ".tasks[$i].review_decision // \"\"" "$TASKS_FILE")
    REVIEW_NOTES=$(yq -r ".tasks[$i].review_notes // \"\"" "$TASKS_FILE")
    DIR=$(yq -r ".tasks[$i].dir // \"\"" "$TASKS_FILE")
    BRANCH=$(yq -r ".tasks[$i].branch // \"\"" "$TASKS_FILE")
    WORKTREE=$(yq -r ".tasks[$i].worktree // \"\"" "$TASKS_FILE")
    WORKTREE_CLEANED=$(yq -r ".tasks[$i].worktree_cleaned // false" "$TASKS_FILE")
    CREATED_AT=$(yq -r ".tasks[$i].created_at // \"\"" "$TASKS_FILE")
    UPDATED_AT=$(yq -r ".tasks[$i].updated_at // \"\"" "$TASKS_FILE")
    GH_ISSUE_NUMBER=$(yq -r ".tasks[$i].gh_issue_number // \"\"" "$TASKS_FILE")
    GH_STATE=$(yq -r ".tasks[$i].gh_state // \"\"" "$TASKS_FILE")
    GH_URL=$(yq -r ".tasks[$i].gh_url // \"\"" "$TASKS_FILE")
    GH_UPDATED_AT=$(yq -r ".tasks[$i].gh_updated_at // \"\"" "$TASKS_FILE")
    GH_SYNCED_AT=$(yq -r ".tasks[$i].gh_synced_at // \"\"" "$TASKS_FILE")
    GH_LAST_FEEDBACK_AT=$(yq -r ".tasks[$i].gh_last_feedback_at // \"\"" "$TASKS_FILE")
    GH_PROJECT_ITEM_ID=$(yq -r ".tasks[$i].gh_project_item_id // \"\"" "$TASKS_FILE")
    GH_ARCHIVED=$(yq -r ".tasks[$i].gh_archived // false" "$TASKS_FILE")

    # Normalize booleans → integers
    [ "$NEEDS_HELP" = "true" ] && NEEDS_HELP=1 || NEEDS_HELP=0
    [ "$WORKTREE_CLEANED" = "true" ] && WORKTREE_CLEANED=1 || WORKTREE_CLEANED=0
    [ "$GH_ARCHIVED" = "true" ] && GH_ARCHIVED=1 || GH_ARCHIVED=0

    # Normalize nulls → empty strings for SQL
    _sql_val() {
      local v="$1"
      if [ -z "$v" ] || [ "$v" = "null" ]; then
        echo "NULL"
      else
        echo "'$(printf '%s' "$v" | sed "s/'/''/g")'"
      fi
    }

    PARENT_VAL=$(_sql_val "$PARENT_ID")
    GH_ISSUE_VAL=$(_sql_val "$GH_ISSUE_NUMBER")

    sqlite3 "$DB_PATH" "INSERT INTO tasks (
      id, title, body, status, agent, agent_model, agent_profile, complexity,
      parent_id, route_reason, route_warning, summary, reason,
      needs_help, attempts, last_error, prompt_hash, last_comment_hash,
      retry_at, review_decision, review_notes,
      dir, branch, worktree, worktree_cleaned,
      created_at, updated_at,
      gh_issue_number, gh_state, gh_url, gh_updated_at,
      gh_synced_at, gh_last_feedback_at, gh_project_item_id, gh_archived
    ) VALUES (
      $ID, $(_sql_val "$TITLE"), $(_sql_val "$BODY"), $(_sql_val "$STATUS"),
      $(_sql_val "$AGENT"), $(_sql_val "$AGENT_MODEL"), $(_sql_val "$AGENT_PROFILE"), $(_sql_val "$COMPLEXITY"),
      $PARENT_VAL, $(_sql_val "$ROUTE_REASON"), $(_sql_val "$ROUTE_WARNING"),
      $(_sql_val "$SUMMARY"), $(_sql_val "$REASON"),
      $NEEDS_HELP, $ATTEMPTS, $(_sql_val "$LAST_ERROR"),
      $(_sql_val "$PROMPT_HASH"), $(_sql_val "$LAST_COMMENT_HASH"),
      $(_sql_val "$RETRY_AT"), $(_sql_val "$REVIEW_DECISION"), $(_sql_val "$REVIEW_NOTES"),
      $(_sql_val "$DIR"), $(_sql_val "$BRANCH"), $(_sql_val "$WORKTREE"), $WORKTREE_CLEANED,
      $(_sql_val "$CREATED_AT"), $(_sql_val "$UPDATED_AT"),
      $GH_ISSUE_VAL, $(_sql_val "$GH_STATE"), $(_sql_val "$GH_URL"),
      $(_sql_val "$GH_UPDATED_AT"), $(_sql_val "$GH_SYNCED_AT"),
      $(_sql_val "$GH_LAST_FEEDBACK_AT"), $(_sql_val "$GH_PROJECT_ITEM_ID"), $GH_ARCHIVED
    );"

    # Migrate labels
    LABEL_COUNT=$(yq -r ".tasks[$i].labels | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$LABEL_COUNT" -gt 0 ] && seq 0 $((LABEL_COUNT - 1)) || true); do
      LABEL=$(yq -r ".tasks[$i].labels[$j]" "$TASKS_FILE")
      [ -z "$LABEL" ] || [ "$LABEL" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO task_labels (task_id, label) VALUES ($ID, '$(printf '%s' "$LABEL" | sed "s/'/''/g")');"
    done

    # Migrate history
    HIST_COUNT=$(yq -r ".tasks[$i].history | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$HIST_COUNT" -gt 0 ] && seq 0 $((HIST_COUNT - 1)) || true); do
      HTS=$(yq -r ".tasks[$i].history[$j].ts // \"\"" "$TASKS_FILE")
      HSTATUS=$(yq -r ".tasks[$i].history[$j].status // \"\"" "$TASKS_FILE")
      HNOTE=$(yq -r ".tasks[$i].history[$j].note // \"\"" "$TASKS_FILE")
      sqlite3 "$DB_PATH" "INSERT INTO task_history (task_id, ts, status, note) VALUES ($ID, $(_sql_val "$HTS"), $(_sql_val "$HSTATUS"), $(_sql_val "$HNOTE"));"
    done

    # Migrate children
    CHILD_COUNT=$(yq -r ".tasks[$i].children | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$CHILD_COUNT" -gt 0 ] && seq 0 $((CHILD_COUNT - 1)) || true); do
      CID=$(yq -r ".tasks[$i].children[$j]" "$TASKS_FILE")
      [ -z "$CID" ] || [ "$CID" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO task_children (parent_id, child_id) VALUES ($ID, $CID);"
    done

    # Migrate files_changed
    FILE_COUNT=$(yq -r ".tasks[$i].files_changed | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$FILE_COUNT" -gt 0 ] && seq 0 $((FILE_COUNT - 1)) || true); do
      FPATH=$(yq -r ".tasks[$i].files_changed[$j]" "$TASKS_FILE")
      [ -z "$FPATH" ] || [ "$FPATH" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO task_files (task_id, file_path) VALUES ($ID, '$(printf '%s' "$FPATH" | sed "s/'/''/g")');"
    done

    # Migrate accomplished
    ACC_COUNT=$(yq -r ".tasks[$i].accomplished | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$ACC_COUNT" -gt 0 ] && seq 0 $((ACC_COUNT - 1)) || true); do
      ITEM=$(yq -r ".tasks[$i].accomplished[$j]" "$TASKS_FILE")
      [ -z "$ITEM" ] || [ "$ITEM" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT INTO task_accomplished (task_id, item) VALUES ($ID, '$(printf '%s' "$ITEM" | sed "s/'/''/g")');"
    done

    # Migrate remaining
    REM_COUNT=$(yq -r ".tasks[$i].remaining | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$REM_COUNT" -gt 0 ] && seq 0 $((REM_COUNT - 1)) || true); do
      ITEM=$(yq -r ".tasks[$i].remaining[$j]" "$TASKS_FILE")
      [ -z "$ITEM" ] || [ "$ITEM" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT INTO task_remaining (task_id, item) VALUES ($ID, '$(printf '%s' "$ITEM" | sed "s/'/''/g")');"
    done

    # Migrate blockers
    BLK_COUNT=$(yq -r ".tasks[$i].blockers | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$BLK_COUNT" -gt 0 ] && seq 0 $((BLK_COUNT - 1)) || true); do
      ITEM=$(yq -r ".tasks[$i].blockers[$j]" "$TASKS_FILE")
      [ -z "$ITEM" ] || [ "$ITEM" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT INTO task_blockers (task_id, item) VALUES ($ID, '$(printf '%s' "$ITEM" | sed "s/'/''/g")');"
    done

    # Migrate selected_skills
    SKILL_COUNT=$(yq -r ".tasks[$i].selected_skills | length" "$TASKS_FILE" 2>/dev/null || echo "0")
    for j in $([ "$SKILL_COUNT" -gt 0 ] && seq 0 $((SKILL_COUNT - 1)) || true); do
      SKILL=$(yq -r ".tasks[$i].selected_skills[$j]" "$TASKS_FILE")
      [ -z "$SKILL" ] || [ "$SKILL" = "null" ] && continue
      sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO task_selected_skills (task_id, skill) VALUES ($ID, '$(printf '%s' "$SKILL" | sed "s/'/''/g")');"
    done

    printf '  task %d: %s (%s)\n' "$ID" "$TITLE" "$STATUS"
  done
else
  echo "==> No tasks file found at $TASKS_FILE, skipping task migration"
fi

# ============================================================
# Migrate jobs
# ============================================================
JOBS_FILE="${JOBS_PATH:-${ORCH_HOME}/jobs.yml}"
if [ -f "$JOBS_FILE" ]; then
  JOB_COUNT=$(yq -r '.jobs | length' "$JOBS_FILE" 2>/dev/null || echo "0")
  echo "==> Migrating $JOB_COUNT jobs from $JOBS_FILE"

  _sql_val() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "null" ]; then
      echo "NULL"
    else
      echo "'$(printf '%s' "$v" | sed "s/'/''/g")'"
    fi
  }

  for i in $(seq 0 $((JOB_COUNT - 1))); do
    JOB_ID=$(yq -r ".jobs[$i].id" "$JOBS_FILE")
    TITLE=$(yq -r ".jobs[$i].title // .jobs[$i].task.title // \"\"" "$JOBS_FILE")
    SCHEDULE=$(yq -r ".jobs[$i].schedule" "$JOBS_FILE")
    TYPE=$(yq -r ".jobs[$i].type // \"task\"" "$JOBS_FILE")
    COMMAND=$(yq -r ".jobs[$i].command // \"\"" "$JOBS_FILE")
    BODY=$(yq -r ".jobs[$i].body // .jobs[$i].task.body // \"\"" "$JOBS_FILE")
    # Labels can be an array (in .task.labels) or a string; normalize to CSV
    LABELS=$(yq -r '(.jobs['"$i"'].labels // .jobs['"$i"'].task.labels // []) | join(",")' "$JOBS_FILE" 2>/dev/null || echo "")
    AGENT=$(yq -r ".jobs[$i].agent // .jobs[$i].task.agent // \"\"" "$JOBS_FILE")
    DIR=$(yq -r ".jobs[$i].dir // \"\"" "$JOBS_FILE")
    ENABLED=$(yq -r ".jobs[$i].enabled // true" "$JOBS_FILE")
    ACTIVE_TASK_ID=$(yq -r ".jobs[$i].active_task_id // \"\"" "$JOBS_FILE")
    LAST_RUN=$(yq -r ".jobs[$i].last_run // \"\"" "$JOBS_FILE")
    LAST_TASK_STATUS=$(yq -r ".jobs[$i].last_task_status // \"\"" "$JOBS_FILE")

    [ "$ENABLED" = "true" ] && ENABLED=1 || ENABLED=0
    ACTIVE_VAL=$(_sql_val "$ACTIVE_TASK_ID")

    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    sqlite3 "$DB_PATH" "INSERT INTO jobs (
      id, title, schedule, type, command, body, labels, agent, dir,
      enabled, active_task_id, last_run, last_task_status, created_at
    ) VALUES (
      $(_sql_val "$JOB_ID"), $(_sql_val "$TITLE"), $(_sql_val "$SCHEDULE"),
      $(_sql_val "$TYPE"), $(_sql_val "$COMMAND"), $(_sql_val "$BODY"),
      $(_sql_val "$LABELS"), $(_sql_val "$AGENT"), $(_sql_val "$DIR"),
      $ENABLED, $ACTIVE_VAL, $(_sql_val "$LAST_RUN"), $(_sql_val "$LAST_TASK_STATUS"),
      '$NOW'
    );"

    printf '  job %s: %s (%s)\n' "$JOB_ID" "$TITLE" "$SCHEDULE"
  done
else
  echo "==> No jobs file found at $JOBS_FILE, skipping job migration"
fi

# ============================================================
# Verify
# ============================================================
MIGRATED_TASKS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks;")
MIGRATED_JOBS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM jobs;")
MIGRATED_HISTORY=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM task_history;")
MIGRATED_LABELS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM task_labels;")

echo ""
echo "==> Migration complete!"
echo "    Database: $DB_PATH"
echo "    Tasks:    $MIGRATED_TASKS"
echo "    Jobs:     $MIGRATED_JOBS"
echo "    History:  $MIGRATED_HISTORY entries"
echo "    Labels:   $MIGRATED_LABELS entries"
echo ""
echo "    Backup your YAML files before removing them:"
echo "    cp $TASKS_FILE ${TASKS_FILE}.bak"
[ -f "$JOBS_FILE" ] && echo "    cp $JOBS_FILE ${JOBS_FILE}.bak"
