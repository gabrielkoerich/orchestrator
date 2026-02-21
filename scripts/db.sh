#!/usr/bin/env bash
# Beads-backed database layer for orchestrator.
# Sourced by lib.sh — provides db_* functions that delegate to the bd CLI.
# Task data is stored in .beads/ (Dolt-backed), jobs in a JSON file.
#
# All task IDs are beads hash strings (e.g., "orchestrator-abc").
# shellcheck disable=SC2155

JOBS_FILE="${JOBS_FILE:-${ORCH_HOME}/jobs.yml}"

# ============================================================
# Core helpers
# ============================================================

# Run bd in project context (stdout suppressed — fire-and-forget)
_bd() {
  local dir="${PROJECT_DIR:-.}"
  (cd "$dir" && bd --quiet "$@") >/dev/null 2>/dev/null
}

# Run bd in project context (stdout captured — for create --silent etc.)
_bd_out() {
  local dir="${PROJECT_DIR:-.}"
  (cd "$dir" && bd --quiet "$@") 2>/dev/null
}

# Run bd with JSON output
_bd_json() {
  local dir="${PROJECT_DIR:-.}"
  (cd "$dir" && bd --json --quiet "$@") 2>/dev/null
}

# Initialize beads in project directory
db_init() {
  local dir="${PROJECT_DIR:-.}"
  if [ ! -d "$dir/.beads" ]; then
    (cd "$dir" && bd init --quiet >/dev/null 2>/dev/null) || true
    _bd config set status.custom "new,routed,in_progress,blocked,needs_review,in_review,done" || true
  fi
  # Ensure jobs file exists
  if [ ! -f "$JOBS_FILE" ]; then
    printf 'jobs: []\n' > "$JOBS_FILE"
  fi
}

db_exists() {
  local dir="${PROJECT_DIR:-.}"
  [ -d "$dir/.beads" ]
}

# Merge metadata: reads existing, deep-merges with new JSON, writes back.
# Usage: _bd_meta_merge <id> <new_metadata_json>
_bd_meta_merge() {
  local id="$1" new_meta="$2"
  local dir="${PROJECT_DIR:-.}"
  local existing
  existing=$(cd "$dir" && bd --json --quiet show "$id" 2>/dev/null | jq -c '.[0].metadata // {}' 2>/dev/null) || existing='{}'
  [ -z "$existing" ] || [ "$existing" = "null" ] && existing='{}'
  local merged
  merged=$(printf '%s' "$existing" | jq -c --argjson n "$new_meta" '. * $n') || merged="$new_meta"
  (cd "$dir" && bd --quiet update "$id" --metadata "$merged") >/dev/null 2>/dev/null
}

# Escape for jq string embedding
_jq_escape() {
  printf '%s' "${1:-}" | jq -Rs '.' 2>/dev/null
}

# ============================================================
# Task CRUD
# ============================================================

# Read a single field from a task.
# Usage: db_task_field <id> <column>
# Core fields: title, status, description (body alias)
# Extended fields stored in metadata: agent, branch, worktree, gh_issue_number, etc.
db_task_field() {
  local id="$1" field="$2"
  local json
  json=$(_bd_json show "$id" 2>/dev/null) || return 0

  case "$field" in
    title)       printf '%s' "$json" | jq -r '.[0].title // empty' ;;
    body)        printf '%s' "$json" | jq -r '.[0].description // empty' ;;
    description) printf '%s' "$json" | jq -r '.[0].description // empty' ;;
    status)      printf '%s' "$json" | jq -r '.[0].status // empty' ;;
    created_at)  printf '%s' "$json" | jq -r '.[0].created_at // empty' ;;
    updated_at)  printf '%s' "$json" | jq -r '.[0].updated_at // empty' ;;
    dir)         printf '%s' "$json" | jq -r '.[0].metadata.dir // empty' ;;
    *)           printf '%s' "$json" | jq -r ".[0].metadata.${field} // empty" ;;
  esac
}

# Update a single field on a task.
# Usage: db_task_set <id> <column> <value>
db_task_set() {
  local id="$1" field="$2" value="$3"
  case "$field" in
    title)       _bd update "$id" --title "$value" ;;
    body|description) _bd update "$id" -d "$value" ;;
    status)      _bd update "$id" -s "$value" ;;
    *)
      # Store in metadata (merge, don't replace)
      local meta_json
      meta_json=$(printf '{}' | jq -c --arg k "$field" --arg v "$value" '.[$k] = $v')
      _bd_meta_merge "$id" "$meta_json"
      ;;
  esac
}

# Atomically claim a task — returns 1 if someone else already claimed it.
# Usage: db_task_claim <id> <from_status> <to_status>
db_task_claim() {
  local id="$1" from_status="$2" to_status="$3"
  local current
  current=$(db_task_field "$id" "status")
  if [ "$current" = "$from_status" ]; then
    _bd update "$id" -s "$to_status"
    return 0
  fi
  return 1
}

# Count tasks, optionally filtered by status and/or dir.
# Usage: db_task_count [status] [dir]
db_task_count() {
  local _tc_status="${1:-}" _tc_dir="${2:-}"
  local all_json
  all_json=$(_bd_json list -n 0 --all 2>/dev/null) || all_json='[]'

  local filter="true"
  [ -n "$_tc_status" ] && filter="${filter} and .status == \"${_tc_status}\""
  [ -n "$_tc_dir" ] && filter="${filter} and (.metadata.dir == \"${_tc_dir}\" or .metadata.dir == null or .metadata.dir == \"\")"

  printf '%s' "$all_json" | jq "[.[] | select(${filter})] | length" 2>/dev/null || echo 0
}

# Get task IDs matching a status, excluding tasks with a specific label.
# Usage: db_task_ids_by_status <status> [exclude_label]
db_task_ids_by_status() {
  local _ids_status="$1" exclude_label="${2:-}"
  local json
  json=$(_bd_json list -n 0 --all 2>/dev/null) || json='[]'
  if [ -n "$exclude_label" ]; then
    printf '%s' "$json" | jq -r --arg s "$_ids_status" --arg lbl "$exclude_label" '.[] | select(.status == $s) | select((.labels // []) | map(select(. == $lbl)) | length == 0) | .id'
  else
    printf '%s' "$json" | jq -r --arg s "$_ids_status" '.[] | select(.status == $s) | .id'
  fi
}

# Create a new task. Returns the new task ID.
# Usage: db_create_task <title> [body] [dir] [labels_csv] [parent_id] [agent]
db_create_task() {
  local title="$1" body="${2:-}" dir="${3:-${PROJECT_DIR:-}}"
  local labels_csv="${4:-}" parent_id="${5:-}" agent="${6:-}"

  local args=(create "$title" --silent)
  [ -n "$body" ] && args+=(-d "$body")
  [ -n "$parent_id" ] && args+=(--parent "$parent_id")

  local new_id
  new_id=$(_bd_out "${args[@]}") || return 1

  # Store extended fields in metadata
  local meta='{}'
  [ -n "$dir" ] && meta=$(printf '%s' "$meta" | jq -c --arg v "$dir" '.dir = $v')
  [ -n "$agent" ] && meta=$(printf '%s' "$meta" | jq -c --arg v "$agent" '.agent = $v')
  meta=$(printf '%s' "$meta" | jq -c '.attempts = 0 | .needs_help = false | .worktree_cleaned = false | .gh_archived = false')

  _bd update "$new_id" -s "new"
  _bd_meta_merge "$new_id" "$meta"

  # Add labels
  if [ -n "$labels_csv" ]; then
    IFS=',' read -ra _labels <<< "$labels_csv"
    for _l in "${_labels[@]}"; do
      _l=$(printf '%s' "$_l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$_l" ] && continue
      _bd label add "$new_id" "$_l"
    done
  fi

  echo "$new_id"
}

# ============================================================
# Task array fields (labels, history, files, children, etc.)
# ============================================================

# Append a history entry as a beads comment.
# Usage: db_append_history <task_id> <status> <note>
db_append_history() {
  local task_id="$1" _ah_status="$2" note="$3"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _bd comments add "$task_id" "[$now] $_ah_status: $note" 2>/dev/null || true
}

# Get task history from comments (formatted).
db_task_history() {
  local task_id="$1"
  _bd_json comments "$task_id" 2>/dev/null | jq -r '.[] | (.text // .body)' 2>/dev/null || true
}

# Get task labels as newline-separated list.
db_task_labels() {
  local task_id="$1"
  _bd_json show "$task_id" 2>/dev/null | jq -r '.[0].labels // [] | .[]' 2>/dev/null || true
}

# Get task labels as comma-separated string.
db_task_labels_csv() {
  local task_id="$1"
  _bd_json show "$task_id" 2>/dev/null | jq -r '.[0].labels // [] | join(",")' 2>/dev/null || true
}

# Get task labels as JSON array.
db_task_labels_json() {
  local task_id="$1"
  _bd_json show "$task_id" 2>/dev/null | jq -c '.[0].labels // []' 2>/dev/null || echo '[]'
}

# Set labels for a task (replaces existing).
# Usage: db_set_labels <task_id> <labels_csv>
db_set_labels() {
  local task_id="$1" labels_csv="$2"
  IFS=',' read -ra _labels <<< "$labels_csv"
  local args=()
  for _l in "${_labels[@]}"; do
    _l=$(printf '%s' "$_l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$_l" ] && continue
    args+=("$_l")
  done
  if [ ${#args[@]} -gt 0 ]; then
    _bd update "$task_id" --set-labels "$(IFS=,; echo "${args[*]}")"
  else
    _bd update "$task_id" --set-labels ""
  fi
}

# Add a label to a task.
db_add_label() {
  local task_id="$1" label="$2"
  _bd label add "$task_id" "$label" 2>/dev/null || true
}

# Remove a label from a task.
db_remove_label() {
  local task_id="$1" label="$2"
  _bd label remove "$task_id" "$label" 2>/dev/null || true
}

# Check if a task has a specific label.
db_task_has_label() {
  local task_id="$1" label="$2"
  local labels
  labels=$(db_task_labels_csv "$task_id")
  printf '%s' ",$labels," | grep -q ",$label,"
}

# Set files_changed for a task (stored in metadata).
db_set_files() {
  local task_id="$1" files_csv="$2"
  local meta
  meta=$(printf '{}' | jq -c --arg f "$files_csv" '.files_changed = ($f | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))')
  _bd_meta_merge "$task_id" "$meta"
}

# Get files_changed as comma-separated string.
db_task_files_csv() {
  local task_id="$1"
  _bd_json show "$task_id" 2>/dev/null | jq -r '.[0].metadata.files_changed // [] | join(", ")' 2>/dev/null || true
}

# Get child task IDs.
db_task_children() {
  local parent_id="$1"
  _bd_json show "$parent_id" --children 2>/dev/null | jq -r '.[].id' 2>/dev/null || true
}

# Set accomplished items (in metadata).
db_set_accomplished() {
  local task_id="$1"; shift
  local items_json='[]'
  for item in "$@"; do
    [ -z "$item" ] && continue
    items_json=$(printf '%s' "$items_json" | jq -c --arg i "$item" '. + [$i]')
  done
  _bd_meta_merge "$task_id" "$(printf '{}' | jq -c --argjson a "$items_json" '.accomplished = $a')"
}

# Set remaining items (in metadata).
db_set_remaining() {
  local task_id="$1"; shift
  local items_json='[]'
  for item in "$@"; do
    [ -z "$item" ] && continue
    items_json=$(printf '%s' "$items_json" | jq -c --arg i "$item" '. + [$i]')
  done
  _bd_meta_merge "$task_id" "$(printf '{}' | jq -c --argjson a "$items_json" '.remaining = $a')"
}

# Set blockers (in metadata).
db_set_blockers() {
  local task_id="$1"; shift
  local items_json='[]'
  for item in "$@"; do
    [ -z "$item" ] && continue
    items_json=$(printf '%s' "$items_json" | jq -c --arg i "$item" '. + [$i]')
  done
  _bd_meta_merge "$task_id" "$(printf '{}' | jq -c --argjson a "$items_json" '.blockers = $a')"
}

# Set selected_skills (in metadata).
db_set_selected_skills() {
  local task_id="$1" skills_csv="$2"
  local meta
  meta=$(printf '{}' | jq -c --arg s "$skills_csv" '.selected_skills = ($s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))')
  _bd_meta_merge "$task_id" "$meta"
}

# ============================================================
# Task bulk update (multi-field)
# ============================================================

# Update multiple fields on a task at once.
# Usage: db_task_update <id> <field1>=<value1> [field2=value2] ...
db_task_update() {
  local id="$1"; shift
  local meta='{}'
  local bd_args=()

  for pair in "$@"; do
    local field="${pair%%=*}"
    local value="${pair#*=}"

    case "$field" in
      title)       bd_args+=(--title "$value") ;;
      body|description) bd_args+=(-d "$value") ;;
      status)
        if [ "$value" = "NULL" ] || [ "$value" = "null" ]; then
          bd_args+=(-s "new")
        else
          bd_args+=(-s "$value")
        fi
        ;;
      *)
        if [ "$value" = "NULL" ] || [ "$value" = "null" ]; then
          meta=$(printf '%s' "$meta" | jq -c --arg k "$field" '.[$k] = null')
        else
          meta=$(printf '%s' "$meta" | jq -c --arg k "$field" --arg v "$value" '.[$k] = $v')
        fi
        ;;
    esac
  done

  # Apply core fields (title, status, etc.) first
  if [ ${#bd_args[@]} -gt 0 ]; then
    _bd update "$id" "${bd_args[@]}"
  fi

  # Merge metadata if any extended fields were set
  if [ "$meta" != '{}' ]; then
    _bd_meta_merge "$id" "$meta"
  fi
}

# ============================================================
# Task query helpers
# ============================================================

# Get a full task as JSON.
db_task_json() {
  local id="$1"
  local json
  json=$(_bd_json show "$id" 2>/dev/null) || return 1
  local comments
  comments=$(_bd_json comments "$id" 2>/dev/null) || comments='[]'

  printf '%s' "$json" | jq --argjson comments "$comments" '
    .[0] + {
      history: ($comments // []),
      labels: (.labels // [])
    }'
}

# Load all task fields into exported shell variables.
# Usage: db_load_task <id>
db_load_task() {
  local id="$1"
  local json
  json=$(_bd_json show "$id" 2>/dev/null) || return 1
  [ "$(printf '%s' "$json" | jq 'length')" -eq 0 ] && return 1

  export TASK_TITLE=$(printf '%s' "$json" | jq -r '.[0].title // ""')
  export TASK_BODY=$(printf '%s' "$json" | jq -r '.[0].description // ""')
  export TASK_STATUS=$(printf '%s' "$json" | jq -r '.[0].status // "new"')
  export TASK_LABELS=$(db_task_labels_csv "$id")

  # Extended fields from metadata
  local m='.[0].metadata'
  export TASK_AGENT=$(printf '%s' "$json" | jq -r "${m}.agent // empty")
  export AGENT_MODEL=$(printf '%s' "$json" | jq -r "${m}.agent_model // empty")
  export TASK_COMPLEXITY=$(printf '%s' "$json" | jq -r "${m}.complexity // \"medium\"")
  export AGENT_PROFILE_JSON=$(printf '%s' "$json" | jq -r "${m}.agent_profile // \"{}\"")
  export ATTEMPTS=$(printf '%s' "$json" | jq -r "${m}.attempts // \"0\"")
  export TASK_PARENT_ID=$(printf '%s' "$json" | jq -r '.[0].parent // empty')
  export GH_ISSUE_NUMBER=$(printf '%s' "$json" | jq -r "${m}.gh_issue_number // empty")
  export TASK_DIR=$(printf '%s' "$json" | jq -r "${m}.dir // empty")
  export TASK_BRANCH=$(printf '%s' "$json" | jq -r "${m}.branch // empty")
  export TASK_WORKTREE=$(printf '%s' "$json" | jq -r "${m}.worktree // empty")
  export TASK_SUMMARY=$(printf '%s' "$json" | jq -r "${m}.summary // empty")
  export TASK_REASON=$(printf '%s' "$json" | jq -r "${m}.reason // empty")
  export TASK_LAST_ERROR=$(printf '%s' "$json" | jq -r "${m}.last_error // empty")
  export TASK_PROMPT_HASH=$(printf '%s' "$json" | jq -r "${m}.prompt_hash // empty")
  export TASK_UPDATED_AT=$(printf '%s' "$json" | jq -r '.[0].updated_at // empty')
  export TASK_GH_SYNCED_AT=$(printf '%s' "$json" | jq -r "${m}.gh_synced_at // empty")
  export TASK_GH_STATE=$(printf '%s' "$json" | jq -r "${m}.gh_state // empty")
  export TASK_GH_URL=$(printf '%s' "$json" | jq -r "${m}.gh_url // empty")
  export TASK_GH_UPDATED_AT=$(printf '%s' "$json" | jq -r "${m}.gh_updated_at // empty")
  export TASK_GH_LAST_FEEDBACK_AT=$(printf '%s' "$json" | jq -r "${m}.gh_last_feedback_at // empty")
  export TASK_GH_PROJECT_ITEM_ID=$(printf '%s' "$json" | jq -r "${m}.gh_project_item_id // empty")
  export TASK_GH_ARCHIVED=$(printf '%s' "$json" | jq -r "${m}.gh_archived // \"false\"")
  export TASK_NEEDS_HELP=$(printf '%s' "$json" | jq -r "${m}.needs_help // \"false\"")
  export TASK_LAST_COMMENT_HASH=$(printf '%s' "$json" | jq -r "${m}.last_comment_hash // empty")
  export TASK_REVIEW_DECISION=$(printf '%s' "$json" | jq -r "${m}.review_decision // empty")
  export TASK_REVIEW_NOTES=$(printf '%s' "$json" | jq -r "${m}.review_notes // empty")
  export TASK_RETRY_AT=$(printf '%s' "$json" | jq -r "${m}.retry_at // empty")
  export TASK_CREATED_AT=$(printf '%s' "$json" | jq -r '.[0].created_at // empty')
  export TASK_WORKTREE_CLEANED=$(printf '%s' "$json" | jq -r "${m}.worktree_cleaned // \"false\"")
  export TASK_ROUTE_REASON=$(printf '%s' "$json" | jq -r "${m}.route_reason // empty")
  export TASK_ROUTE_WARNING=$(printf '%s' "$json" | jq -r "${m}.route_warning // empty")
  export TASK_DURATION=$(printf '%s' "$json" | jq -r "${m}.duration // \"0\"")
  export TASK_INPUT_TOKENS=$(printf '%s' "$json" | jq -r "${m}.input_tokens // \"0\"")
  export TASK_OUTPUT_TOKENS=$(printf '%s' "$json" | jq -r "${m}.output_tokens // \"0\"")
  export TASK_STDERR_SNIPPET=$(printf '%s' "$json" | jq -r "${m}.stderr_snippet // empty")
  export TASK_GH_SYNCED_STATUS=$(printf '%s' "$json" | jq -r "${m}.gh_synced_status // empty")
  export TASK_DECOMPOSE=$(printf '%s' "$json" | jq -r "${m}.decompose // \"0\"")

  # Role from agent profile
  ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | jq -r '.role // "general"' 2>/dev/null || echo "general")
  export ROLE

  # Selected skills from metadata
  export SELECTED_SKILLS
  SELECTED_SKILLS=$(printf '%s' "$json" | jq -r "${m}.selected_skills // [] | join(\",\")" 2>/dev/null || true)
}

# Find task ID by GitHub issue number.
db_task_id_by_gh_issue() {
  local issue_num="$1"
  # Search by label gh:<num> (faster than scanning metadata)
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r --arg n "$issue_num" '.[] | select(.metadata.gh_issue_number == $n or (.labels // [] | any(. == "gh:\($n)"))) | .id' \
    | head -1
}

# Find task ID by branch + dir.
db_task_id_by_branch() {
  local branch="$1" dir="$2"
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r --arg b "$branch" --arg d "$dir" '.[] | select(.metadata.branch == $b and .metadata.dir == $d) | .id' \
    | head -1
}

# Get dirty tasks that need GitHub sync.
db_dirty_task_ids() {
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r '.[] | select(
        (.metadata.gh_synced_at == null or .metadata.gh_synced_at != .updated_at or .metadata.gh_issue_number == null)
        and (.status != "done" or .metadata.gh_synced_at != .updated_at)
      ) | .id'
}

# Mark a task as synced to GitHub.
db_task_set_synced() {
  local id="$1" status="$2"
  local updated_at
  updated_at=$(db_task_field "$id" "updated_at")
  _bd_meta_merge "$id" "$(printf '{}' | jq -c --arg s "$status" --arg t "$updated_at" '.gh_synced_at = $t | .gh_synced_status = $s')"
}

# Get task history as formatted strings (last N entries).
db_task_history_formatted() {
  local id="$1" limit="${2:-5}"
  _bd_json comments "$id" 2>/dev/null \
    | jq -r ".[-${limit}:] | .[].body" 2>/dev/null || true
}

# Get accomplished items as newline-separated list.
db_task_accomplished() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.accomplished // [] | .[]' 2>/dev/null || true
}

# Get remaining items.
db_task_remaining() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.remaining // [] | .[]' 2>/dev/null || true
}

# Get blockers.
db_task_blockers() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.blockers // [] | .[]' 2>/dev/null || true
}

# Get task files changed.
db_task_files() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.files_changed // [] | .[]' 2>/dev/null || true
}

# Create task from GitHub issue (used by gh_pull.sh).
db_create_task_from_gh() {
  local title="$1" body="$2" labels_csv="$3" gh_issue_number="$4"
  local gh_state="$5" gh_url="$6" gh_updated_at="$7" dir="${8:-${PROJECT_DIR:-}}"

  local args=(create "$title" --silent)
  [ -n "$body" ] && args+=(-d "$body")

  local new_id
  new_id=$(_bd_out "${args[@]}") || return 1

  # Store GH fields in metadata
  local meta
  meta=$(jq -nc --arg dir "$dir" --arg ghi "$gh_issue_number" --arg ghs "$gh_state" \
    --arg ghu "$gh_url" --arg ghup "$gh_updated_at" \
    '{dir: $dir, gh_issue_number: $ghi, gh_state: $ghs, gh_url: $ghu, gh_updated_at: $ghup,
      attempts: 0, needs_help: false, worktree_cleaned: false, gh_archived: false}')

  _bd update "$new_id" -s "new" --external-ref "gh-${gh_issue_number}"
  _bd_meta_merge "$new_id" "$meta"

  # Add labels + gh:<num> for quick lookup
  _bd label add "$new_id" "gh:${gh_issue_number}" 2>/dev/null || true
  if [ -n "$labels_csv" ]; then
    IFS=',' read -ra _labels <<< "$labels_csv"
    for _l in "${_labels[@]}"; do
      _l=$(printf '%s' "$_l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$_l" ] && continue
      _bd label add "$new_id" "$_l" 2>/dev/null || true
    done
  fi

  echo "$new_id"
}

# Check if a comment body hash matches the stored hash (for dedup).
db_should_skip_comment() {
  local task_id="$1" body="$2"
  local new_hash
  new_hash=$(printf '%s' "$body" | shasum -a 256 | cut -c1-16)
  local old_hash
  old_hash=$(db_task_field "$task_id" "last_comment_hash")
  [ "$new_hash" = "$old_hash" ]
}

# Store comment hash after posting.
db_store_comment_hash() {
  local task_id="$1" body="$2"
  local hash
  hash=$(printf '%s' "$body" | shasum -a 256 | cut -c1-16)
  db_task_set "$task_id" "last_comment_hash" "$hash"
}

# Get all task IDs.
db_all_task_ids() {
  _bd_json list -n 0 --all 2>/dev/null | jq -r '.[].id' 2>/dev/null || true
}

# Get total task count.
db_total_task_count() {
  _bd_json list -n 0 --all 2>/dev/null | jq 'length' 2>/dev/null || echo 0
}

# Bulk update for run_task.sh response parsing.
db_store_agent_response() {
  local id="$1" status="$2" summary="$3" reason="$4"
  local needs_help="$5" agent_model="$6" duration="$7"
  local input_tokens="$8" output_tokens="$9"
  shift 9
  local stderr_snippet="${1:-}" prompt_hash="${2:-}"

  local meta
  meta=$(jq -nc --arg s "$summary" --arg r "$reason" --arg nh "$needs_help" \
    --arg am "$agent_model" --arg d "$duration" --arg it "$input_tokens" \
    --arg ot "$output_tokens" --arg ss "$stderr_snippet" --arg ph "$prompt_hash" \
    '{summary: $s, reason: $r, needs_help: $nh, agent_model: $am,
      duration: $d, input_tokens: $it, output_tokens: $ot,
      stderr_snippet: $ss, prompt_hash: $ph,
      last_error: null, retry_at: null}')

  _bd update "$id" -s "$status"
  _bd_meta_merge "$id" "$meta"
}

# Store array data from agent response.
db_store_agent_arrays() {
  local id="$1" accomplished="$2" remaining="$3" blockers="$4" files_changed="$5"
  local meta='{}'

  if [ -n "$accomplished" ]; then
    meta=$(printf '%s' "$meta" | jq -c --arg a "$accomplished" '.accomplished = ($a | split("\n") | map(select(length > 0)))')
  else
    meta=$(printf '%s' "$meta" | jq -c '.accomplished = []')
  fi

  if [ -n "$remaining" ]; then
    meta=$(printf '%s' "$meta" | jq -c --arg r "$remaining" '.remaining = ($r | split("\n") | map(select(length > 0)))')
  else
    meta=$(printf '%s' "$meta" | jq -c '.remaining = []')
  fi

  if [ -n "$blockers" ]; then
    meta=$(printf '%s' "$meta" | jq -c --arg b "$blockers" '.blockers = ($b | split("\n") | map(select(length > 0)))')
  else
    meta=$(printf '%s' "$meta" | jq -c '.blockers = []')
  fi

  if [ -n "$files_changed" ]; then
    meta=$(printf '%s' "$meta" | jq -c --arg f "$files_changed" '.files_changed = ($f | split("\n") | map(select(length > 0)))')
  else
    meta=$(printf '%s' "$meta" | jq -c '.files_changed = []')
  fi

  _bd_meta_merge "$id" "$meta"
}

# ============================================================
# Display helpers
# ============================================================

# Formatted list items
db_task_accomplished_list() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.accomplished // [] | .[] | "- " + .' 2>/dev/null || true
}

db_task_remaining_list() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.remaining // [] | .[] | "- " + .' 2>/dev/null || true
}

db_task_blockers_list() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.blockers // [] | .[] | "- " + .' 2>/dev/null || true
}

db_task_files_list() {
  local id="$1"
  _bd_json show "$id" 2>/dev/null | jq -r '.[0].metadata.files_changed // [] | .[] | "- `" + . + "`"' 2>/dev/null || true
}

# DIR filter: returns jq filter expression
db_dir_where() {
  local project_dir="${PROJECT_DIR:-}"
  local orch_home="${ORCH_HOME:-$HOME/.orchestrator}"
  if [ -z "$project_dir" ] || [ "$project_dir" = "$orch_home" ]; then
    echo "true"  # no filter
  else
    echo "(.metadata.dir == \"$project_dir\" or .metadata.dir == null or .metadata.dir == \"\")"
  fi
}

# Count tasks by status within current dir filter.
db_status_count() {
  local status="$1"
  local dir_filter
  dir_filter=$(db_dir_where)
  _bd_json query "status=${status}" -n 0 2>/dev/null \
    | jq --arg s "$status" "[.[] | select(${dir_filter})] | length" 2>/dev/null || echo 0
}

# Total task count within current dir filter.
db_total_filtered_count() {
  local dir_filter
  dir_filter=$(db_dir_where)
  _bd_json list -n 0 --all 2>/dev/null \
    | jq "[.[] | select(${dir_filter})] | length" 2>/dev/null || echo 0
}

# List tasks as TSV for table display: ID STATUS AGENT ISSUE TITLE
db_task_display_tsv() {
  local extra_filter="${1:-true}" order="${2:-id}" limit="${3:-}"
  local dir_filter
  dir_filter=$(db_dir_where)
  local jq_expr
  jq_expr="[.[] | select(${dir_filter}) | select(${extra_filter})]"
  [ -n "$limit" ] && jq_expr="${jq_expr} | .[:${limit}]"
  jq_expr="${jq_expr} | .[] | [.id, .status, (.metadata.agent // \"-\"), (if .metadata.gh_issue_number then \"#\" + .metadata.gh_issue_number else \"-\" end), .title] | @tsv"

  _bd_json list -n 0 --all 2>/dev/null | jq -r "$jq_expr" 2>/dev/null || true
}

# List tasks as TSV with project column
db_task_display_tsv_global() {
  local extra_filter="${1:-true}" order="${2:-updated_at}" limit="${3:-10}"
  local jq_expr
  jq_expr="[.[] | select(${extra_filter})] | sort_by(.updated_at) | reverse | .[:${limit}] | .[] | [.id, .status, (.metadata.agent // \"-\"), (if .metadata.gh_issue_number then \"#\" + .metadata.gh_issue_number else \"-\" end), (.metadata.dir // \"-\" | split(\"/\") | .[-1:] | join(\"/\")), .title] | @tsv"

  _bd_json list -n 0 --all 2>/dev/null | jq -r "$jq_expr" 2>/dev/null || true
}

# Token usage TSV
db_task_usage_tsv() {
  local dir_filter
  dir_filter=$(db_dir_where)
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r "[.[] | select(${dir_filter}) | select(.metadata.input_tokens != null and (.metadata.input_tokens | tonumber) > 0)] | .[] | [.metadata.input_tokens, (.metadata.output_tokens // \"0\"), (.metadata.duration // \"0\"), (.metadata.agent_model // \"sonnet\")] | @tsv" 2>/dev/null || true
}

# Unique project dirs — from jobs config + PROJECT_DIR.
db_task_projects() {
  {
    # From jobs file
    _read_jobs | jq -r '.[].dir // empty' 2>/dev/null || true
    # Current project dir
    [ -n "${PROJECT_DIR:-}" ] && echo "$PROJECT_DIR"
  } | sort -u | while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" != "null" ] && [ -d "$d" ] && echo "$d"
  done
}

# Active task count for a specific dir.
db_task_active_count_for_dir() {
  local dir="$1"
  _bd_json list -n 0 2>/dev/null \
    | jq --arg d "$dir" '[.[] | select(.metadata.dir == $d and .status != "done")] | length' 2>/dev/null || echo 0
}

# Root task IDs (no parent).
db_task_roots() {
  local dir_filter
  dir_filter=$(db_dir_where)
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r "[.[] | select(${dir_filter}) | select(.parent == null)] | .[].id" 2>/dev/null || true
}

# Status JSON output
db_status_json() {
  local _dummy="$1"  # was SQL where clause, now ignored
  local dir_filter
  dir_filter=$(db_dir_where)
  local all
  all=$(_bd_json list -n 0 --all 2>/dev/null) || all='[]'

  printf '%s' "$all" | jq --arg df "$dir_filter" "
    [.[] | select(${dir_filter})] as \$filtered |
    {
      total: (\$filtered | length),
      counts: {
        new: ([.[] | select(${dir_filter}) | select(.status == \"new\")] | length),
        routed: ([.[] | select(${dir_filter}) | select(.status == \"routed\")] | length),
        in_progress: ([.[] | select(${dir_filter}) | select(.status == \"in_progress\")] | length),
        blocked: ([.[] | select(${dir_filter}) | select(.status == \"blocked\")] | length),
        done: ([.[] | select(${dir_filter}) | select(.status == \"done\")] | length),
        needs_review: ([.[] | select(${dir_filter}) | select(.status == \"needs_review\")] | length)
      },
      recent: (\$filtered | sort_by(.updated_at) | reverse | .[:10] | [.[] | {
        id: .id, title: .title, status: .status,
        agent: .metadata.agent, gh_issue_number: .metadata.gh_issue_number,
        updated_at: .updated_at
      }])
    }" 2>/dev/null || echo '{"total":0,"counts":{},"recent":[]}'
}

# Tasks with branches (for review_prs.sh)
db_tasks_with_branches() {
  _bd_json list -n 0 --all 2>/dev/null \
    | jq -r '.[] | select(.metadata.branch != null and .metadata.branch != "" and .metadata.branch != "main" and .metadata.branch != "master" and (.status == "done" or .status == "in_review" or .status == "in_progress" or .status == "blocked")) | [.id, .metadata.branch, .status, .title, (.metadata.summary // ""), (.metadata.worktree // ""), (.metadata.agent // ""), (.metadata.gh_issue_number // "")] | @tsv' 2>/dev/null || true
}

# Dirty task count.
db_dirty_task_count() {
  _bd_json list -n 0 --all 2>/dev/null \
    | jq '[.[] | select(
        (.metadata.gh_synced_at == null or .metadata.gh_synced_at != .updated_at or .metadata.gh_issue_number == null)
        and (.status != "done" or .metadata.gh_synced_at != .updated_at)
      )] | length' 2>/dev/null || echo 0
}

# ============================================================
# Job CRUD (YAML file backed — jobs.yml)
# ============================================================

# Read jobs array from YAML as JSON
_read_jobs() {
  if [ -f "$JOBS_FILE" ]; then
    yq -o=json '.jobs // []' "$JOBS_FILE" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

# Write JSON array back to YAML
_write_jobs() {
  local json="$1"
  printf '%s' "$json" | yq -P '{"jobs": .}' > "$JOBS_FILE"
}

db_create_job() {
  local id="$1" title="$2" schedule="$3" type="${4:-task}"
  local body="${5:-}" labels="${6:-}" agent="${7:-}" dir="${8:-}" command="${9:-}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local jobs
  jobs=$(_read_jobs)
  local new_job
  new_job=$(jq -nc --arg id "$id" --arg t "$title" --arg s "$schedule" --arg ty "$type" \
    --arg b "$body" --arg l "$labels" --arg a "$agent" --arg d "$dir" --arg c "$command" --arg n "$now" \
    '{id: $id, title: $t, schedule: $s, type: $ty, command: (if $c == "" then null else $c end),
      body: $b, labels: $l, agent: (if $a == "" then null else $a end),
      dir: $d, enabled: true, active_task_id: null, last_run: null,
      last_task_status: null, created_at: $n}')
  _write_jobs "$(printf '%s' "$jobs" | jq --argjson j "$new_job" '. + [$j]')"
}

db_job_field() {
  local id="$1" field="$2"
  _read_jobs | jq -r --arg id "$id" --arg f "$field" '.[] | select(.id == $id) | .[$f] // empty'
}

db_job_set() {
  local id="$1" field="$2" value="$3"
  local jobs
  jobs=$(_read_jobs)
  _write_jobs "$(printf '%s' "$jobs" | jq --arg id "$id" --arg f "$field" --arg v "$value" \
    '[.[] | if .id == $id then .[$f] = $v else . end]')"
}

db_job_list() {
  _read_jobs | jq -r '.[] | [.id, (.task.title // .title // ""), .schedule, .type, (if .enabled then "1" else "0" end), (.active_task_id // ""), (.last_run // "")] | @tsv'
}

db_job_delete() {
  local id="$1"
  local jobs
  jobs=$(_read_jobs)
  _write_jobs "$(printf '%s' "$jobs" | jq --arg id "$id" '[.[] | select(.id != $id)]')"
}

db_enabled_job_count() {
  _read_jobs | jq '[.[] | select(.enabled == true)] | length'
}

db_enabled_job_ids() {
  _read_jobs | jq -r '.[] | select(.enabled == true) | .id'
}

db_load_job() {
  local jid="$1"
  local row
  row=$(_read_jobs | jq -c --arg id "$jid" '.[] | select(.id == $id and .enabled == true)') || return 1
  [ -z "$row" ] && return 1

  JOB_ID=$(printf '%s' "$row" | jq -r '.id')
  JOB_SCHEDULE=$(printf '%s' "$row" | jq -r '.schedule')
  JOB_TYPE=$(printf '%s' "$row" | jq -r '.type')
  JOB_CMD=$(printf '%s' "$row" | jq -r '.command // ""')
  # Task fields may be nested under .task or at top level (backwards compat)
  JOB_TITLE=$(printf '%s' "$row" | jq -r '.task.title // .title // ""')
  JOB_BODY=$(printf '%s' "$row" | jq -r '.task.body // .body // ""')
  JOB_LABELS=$(printf '%s' "$row" | jq -r '(.task.labels // .labels // []) | if type == "array" then join(",") else . end')
  JOB_AGENT=$(printf '%s' "$row" | jq -r '.task.agent // .agent // ""')
  JOB_DIR=$(printf '%s' "$row" | jq -r '.dir // ""')
  JOB_ACTIVE_TASK_ID=$(printf '%s' "$row" | jq -r '.active_task_id // ""')
  JOB_LAST_RUN=$(printf '%s' "$row" | jq -r '.last_run // ""')
}

# ============================================================
# Locking (no-ops — beads handles concurrency via Dolt)
# ============================================================

db_acquire_lock() { :; }
db_release_lock() { :; }
db_with_lock() { "$@"; }

# ============================================================
# Legacy helpers (compatibility shims)
# ============================================================

# No-op (was SQL helper)
sql_escape() { printf '%s' "${1:-}"; }
db() { :; }
db_row() { :; }
db_json() { echo '[]'; }
db_scalar() { :; }
db_ensure_columns() { :; }
db_export_tasks_yaml() { :; }
db_next_id() { echo "0"; }
