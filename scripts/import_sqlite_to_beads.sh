#!/usr/bin/env bash
# import_sqlite_to_beads.sh — One-time import of active SQLite tasks into Beads
# Usage: import_sqlite_to_beads.sh [project_dir]
#
# Imports tasks whose dir matches the given project into that project's .beads/.
# Skips tasks that are already 'done'.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

PROJECT_DIR="${1:-$(pwd)}"
DB_PATH="${DB_PATH:-${ORCH_HOME}/orchestrator.db}"

if [ ! -f "$DB_PATH" ]; then
  log_err "SQLite database not found at $DB_PATH"
  exit 1
fi

if ! command -v bd >/dev/null 2>&1; then
  log_err "bd (beads) CLI not found. Install: brew install beads"
  exit 1
fi

# Ensure beads is initialized
if [ ! -d "$PROJECT_DIR/.beads" ]; then
  log "Initializing beads in $PROJECT_DIR..."
  (cd "$PROJECT_DIR" && bd init --quiet 2>/dev/null) || true
  (cd "$PROJECT_DIR" && bd config set status.custom "new,routed,in_progress,blocked,needs_review,in_review,done") || true
fi

log "Importing active tasks from $DB_PATH into $PROJECT_DIR/.beads/..."

# Map orchestrator status to beads status
map_status() {
  local status="$1"
  case "$status" in
    new|routed|in_progress|blocked|needs_review|in_review) echo "$status" ;;
    done) echo "closed" ;;
    *) echo "open" ;;
  esac
}

IMPORTED=0
SKIPPED=0

# Export tasks as JSON to handle multiline bodies safely
TASKS_JSON=$(sqlite3 "$DB_PATH" ".mode json" "
  SELECT id, title, body, status, agent, gh_issue_number, complexity
  FROM tasks
  WHERE status NOT IN ('done')
    AND (dir = '$PROJECT_DIR' OR (dir IS NULL AND '$PROJECT_DIR' = '$(pwd)'))
  ORDER BY id;
" 2>/dev/null)

if [ -z "$TASKS_JSON" ] || [ "$TASKS_JSON" = "[]" ]; then
  log "No active tasks found for $PROJECT_DIR"
  exit 0
fi

echo "$TASKS_JSON" | jq -c '.[]' | while IFS= read -r row; do
  id=$(jq -r '.id' <<< "$row")
  title=$(jq -r '.title' <<< "$row")
  body=$(jq -r '.body // ""' <<< "$row")
  status=$(jq -r '.status' <<< "$row")
  agent=$(jq -r '.agent // ""' <<< "$row")
  gh_issue=$(jq -r '.gh_issue_number // 0' <<< "$row")
  complexity=$(jq -r '.complexity // ""' <<< "$row")

  [ -n "$id" ] || continue

  # Check if already imported (by external ref)
  if [ "$gh_issue" != "0" ] && [ "$gh_issue" != "null" ] && [ -n "$gh_issue" ]; then
    EXISTING=$(cd "$PROJECT_DIR" && bd list --json --limit 0 2>/dev/null \
      | jq -r ".[] | select(.external_ref == \"gh-${gh_issue}\") | .id" | head -1)
    if [ -n "$EXISTING" ]; then
      log "  skip task=$id (gh#${gh_issue}) — already imported as $EXISTING"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  BD_STATUS=$(map_status "$status")
  log "  importing task=$id title=\"$title\" status=$status → bd status=$BD_STATUS"

  # Create the task — use --body-file for safe multiline handling
  BODY_FILE=$(mktemp)
  echo "$body" > "$BODY_FILE"
  TASK_ID=$(cd "$PROJECT_DIR" && bd create "$title" --body-file "$BODY_FILE" --silent 2>/dev/null) || { rm -f "$BODY_FILE"; continue; }
  rm -f "$BODY_FILE"

  # Set status
  if [ "$BD_STATUS" != "open" ]; then
    (cd "$PROJECT_DIR" && bd update "$TASK_ID" --status "$BD_STATUS" 2>/dev/null) || true
  fi

  # Set agent as assignee
  if [ -n "$agent" ] && [ "$agent" != "null" ]; then
    (cd "$PROJECT_DIR" && bd update "$TASK_ID" --assignee "$agent" 2>/dev/null) || true
  fi

  # Link to GitHub issue
  if [ "$gh_issue" != "0" ] && [ "$gh_issue" != "null" ] && [ -n "$gh_issue" ]; then
    (cd "$PROJECT_DIR" && bd update "$TASK_ID" --external-ref "gh-${gh_issue}" --add-label "gh:${gh_issue}" 2>/dev/null) || true
  fi

  # Set complexity label
  if [ -n "$complexity" ] && [ "$complexity" != "null" ]; then
    (cd "$PROJECT_DIR" && bd update "$TASK_ID" --add-label "complexity:${complexity}" 2>/dev/null) || true
  fi

  # Store original SQLite ID in metadata for traceability
  (cd "$PROJECT_DIR" && bd update "$TASK_ID" --metadata "{\"sqlite_id\": $id}" 2>/dev/null) || true

  IMPORTED=$((IMPORTED + 1))
done

log "Import complete: $IMPORTED imported, $SKIPPED skipped"
