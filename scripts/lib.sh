#!/usr/bin/env bash
set -euo pipefail

ORCH_HOME="${ORCH_HOME:-$HOME/.orchestrator}"
mkdir -p "$ORCH_HOME"

TASKS_PATH=${TASKS_PATH:-"${ORCH_HOME}/tasks.yml"}
LOCK_PATH=${LOCK_PATH:-"${TASKS_PATH}.lock"}
CONTEXTS_DIR=${CONTEXTS_DIR:-"${ORCH_HOME}/contexts"}
CONFIG_PATH=${CONFIG_PATH:-"${ORCH_HOME}/config.yml"}
JOBS_PATH=${JOBS_PATH:-"${ORCH_HOME}/jobs.yml"}
STATE_DIR=${STATE_DIR:-"${ORCH_HOME}/.orchestrator"}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date -u +"%s"
}

log() {
  echo "$(now_iso) $*"
}

# Log to stderr (for scripts whose stdout is consumed by callers)
log_err() {
  echo "$(now_iso) $*" >&2
}

# Log to the error log file (agent errors, stuck agents, auth issues)
error_log() {
  local error_file="${STATE_DIR}/orchestrator.error.log"
  echo "$(now_iso) $*" >> "$error_file"
  log_err "$@"
}

duration_fmt() {
  local secs="${1:-0}"
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))m $((secs % 60))s"
  else
    echo "$((secs / 3600))h $((secs % 3600 / 60))m"
  fi
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
      log_err "[gh] backoff active for ${remaining}s; skipping request."
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

  if rg -qi "secondary rate limit|rate limit|API rate limit|abuse detection|HTTP 403" "$err"; then
    local delay
    delay=$(gh_backoff_next_delay "$base" "$max")
    gh_backoff_set "$delay" "rate_limit"
    log_err "[gh] rate limit detected; backing off for ${delay}s."
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

render_template() {
  local template_path="$1"
  if [ ! -f "$template_path" ]; then
    log_err "[render_template] template not found: $template_path"
    return 1
  fi
  local output
  output=$(python3 - "$template_path" <<'PY'
import os, sys, re
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()
# Support simple conditional blocks:
# {{#if VAR}} ... {{/if}}
# A block renders only when VAR exists and is not whitespace-only.
pattern = re.compile(r"\{\{#if\s+(\w+)\}\}(.*?)\{\{/if\}\}", re.DOTALL)
while True:
    changed = [False]
    def repl_if(m):
        changed[0] = True
        value = os.environ.get(m.group(1), "")
        return m.group(2) if value.strip() else ""
    data = pattern.sub(repl_if, data)
    if not changed[0]:
        break
data = re.sub(r'\{\{(\w+)\}\}', lambda m: os.environ.get(m.group(1), ''), data)
sys.stdout.write(data)
PY
  )
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "[render_template] python3 failed (exit $rc) for $template_path"
    return "$rc"
  fi
  if [ -z "$output" ]; then
    log_err "[render_template] empty output for $template_path"
    return 1
  fi
  printf '%s' "$output"
}

configure_project_status_field() {
  local project_id="$1"
  # Find the Status field ID
  local fields_json status_field_id
  fields_json=$(gh api graphql \
    -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name } } } } } }' \
    -f project="$project_id" 2>/dev/null || true)
  [ -n "$fields_json" ] || return 0
  status_field_id=$(printf '%s' "$fields_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null | head -n1)
  if [ -z "$status_field_id" ] || [ "$status_field_id" = "null" ]; then
    return 0
  fi
  # Update Status field with orchestrator columns
  gh api graphql \
    -f query="mutation(\$fieldId:ID!){ updateProjectV2Field(input:{fieldId:\$fieldId, singleSelectOptions:[{name:\"Backlog\",color:GRAY,description:\"\"},{name:\"In Progress\",color:YELLOW,description:\"\"},{name:\"Review\",color:ORANGE,description:\"\"},{name:\"Done\",color:GREEN,description:\"\"}]}){ projectV2Field{ ... on ProjectV2SingleSelectField { id name options { id name } } } } }" \
    -f fieldId="$status_field_id" >/dev/null 2>&1 || true
  echo "Configured project status columns: Backlog, In Progress, Review, Done"
}

create_project_board_view() {
  local project_num="$1" owner="$2" owner_type="$3"
  local endpoint
  if [ "$owner_type" = "Organization" ]; then
    endpoint="orgs/$owner/projectsV2/$project_num/views"
  else
    endpoint="users/$owner/projectsV2/$project_num/views"
  fi
  gh api "$endpoint" -X POST \
    -f name="Board" -f layout="board" \
    --header "X-GitHub-Api-Version:2022-11-28" >/dev/null 2>&1 || true
  echo "Created Board view"
}

link_project_to_repo() {
  local project_id="$1" repo="$2"
  local repo_node_id
  repo_node_id=$(gh api "repos/$repo" -q '.node_id' 2>/dev/null || true)
  if [ -n "$repo_node_id" ] && [ "$repo_node_id" != "null" ]; then
    gh api graphql \
      -f query='mutation($projectId:ID!,$repoId:ID!){ linkProjectV2ToRepository(input:{projectId:$projectId, repositoryId:$repoId}){ repository{ id } } }' \
      -f projectId="$project_id" \
      -f repoId="$repo_node_id" >/dev/null 2>&1 || true
    echo "Linked project to $repo"
  fi
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

require_rg() {
  if ! command -v rg >/dev/null 2>&1; then
    echo "rg (ripgrep) is required but not found in PATH." >&2
    exit 1
  fi
}

require_fd() {
  if ! command -v fd >/dev/null 2>&1; then
    echo "fd is required but not found in PATH." >&2
    exit 1
  fi
}

require_agent() {
  local agent="$1"
  if ! command -v "$agent" >/dev/null 2>&1; then
    echo "$agent is required but not found in PATH." >&2
    echo "Install it or choose a different agent." >&2
    exit 1
  fi
}

available_agents() {
  local agents=""
  local disabled=""
  disabled=$(yq -r '.router.disabled_agents // [] | join(",")' "$CONFIG_PATH" 2>/dev/null || true)
  for agent in claude codex opencode; do
    if command -v "$agent" >/dev/null 2>&1; then
      # Skip disabled agents
      if [ -n "$disabled" ] && printf '%s' ",$disabled," | grep -q ",$agent,"; then
        continue
      fi
      if [ -n "$agents" ]; then
        agents="$agents,$agent"
      else
        agents="$agent"
      fi
    fi
  done
  echo "$agents"
}

opposite_agent() {
  local task_agent="${1:-}"
  local agents
  agents=$(available_agents)
  # Pick first available agent that differs from the task's agent
  IFS=',' read -ra agent_list <<< "$agents"
  for a in "${agent_list[@]}"; do
    if [ "$a" != "$task_agent" ]; then
      echo "$a"
      return
    fi
  done
  # Fallback to configured review_agent
  local configured
  configured=$(config_get '.workflow.review_agent // ""')
  if [ -n "$configured" ] && [ "$configured" != "$task_agent" ]; then
    echo "$configured"
    return
  fi
  # Last resort: same agent
  echo "$task_agent"
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

init_jobs_file() {
  if [ ! -f "$JOBS_PATH" ]; then
    if [ -f "jobs.example.yml" ]; then
      cp "jobs.example.yml" "$JOBS_PATH"
    else
      printf 'jobs: []\n' > "$JOBS_PATH"
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

GLOBAL_CONFIG_PATH="${GLOBAL_CONFIG_PATH:-${ORCH_HOME}/config.yml}"

load_project_config() {
  local project_config="${PROJECT_DIR:+${PROJECT_DIR}/.orchestrator.yml}"
  if [ -z "$project_config" ] || [ ! -f "$project_config" ]; then
    return 0
  fi
  ensure_state_dir
  local merged="${STATE_DIR}/config-merged.yml"
  # Deep merge: global config * project config (project wins)
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$GLOBAL_CONFIG_PATH" "$project_config" > "$merged"
  CONFIG_PATH="$merged"
}

config_get() {
  local key="$1"
  if [ -f "$CONFIG_PATH" ]; then
    yq -r "$key" "$CONFIG_PATH"
  else
    echo ""
  fi
}

repo_owner() {
  local repo="${1:-}"
  if [ -z "$repo" ]; then
    repo=$(config_get '.gh.repo // ""')
  fi
  if [ -n "$repo" ] && [ "$repo" != "null" ]; then
    printf '%s' "$repo" | cut -d'/' -f1
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
      log_err "Failed to acquire lock: $LOCK_PATH"
      log_err "Tip: if no orchestrator is running, remove stale locks with 'just unlock'."
      exit 1
    fi
    sleep 0.1
  done
}

release_lock() {
  rmdir "$LOCK_PATH" 2>/dev/null || true
}

lock_mtime() {
  local path="$1" mtime
  mtime=$(stat -f %m "$path" 2>/dev/null) && { echo "$mtime"; return 0; }
  mtime=$(stat -c %Y "$path" 2>/dev/null) && { echo "$mtime"; return 0; }
  echo 0
}

lock_is_stale() {
  local path="$1"
  local stale_seconds=${LOCK_STALE_SECONDS:-600}
  local mtime
  mtime=$(lock_mtime "$path")
  if [ -z "$mtime" ] || [ "$mtime" -eq 0 ] 2>/dev/null; then
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
  local _wl_rc=0
  "$@" || _wl_rc=$?
  release_lock
  return "$_wl_rc"
}

append_history() {
  local task_id="$1"
  local status="$2"
  local note="$3"
  local ts
  ts=$(now_iso)
  export ts status note

  with_lock yq -i \
    "(.tasks[] | select(.id == $task_id) | .history) += [{\"ts\": strenv(ts), \"status\": strenv(status), \"note\": strenv(note)}]" \
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

build_repo_tree() {
  local dir="${1:-$PROJECT_DIR}"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then return; fi
  if command -v git >/dev/null 2>&1 && (cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    (cd "$dir" && git ls-files --cached --others --exclude-standard | head -200 | sort)
  else
    (cd "$dir" && find . -type f \
      -not -path './.git/*' \
      -not -path './node_modules/*' \
      -not -path './vendor/*' \
      -not -path './.orchestrator/*' \
      -not -path '*/target/*' \
      -not -path './__pycache__/*' \
      -not -path './.venv/*' \
      | head -200 | sort)
  fi
}

build_project_instructions() {
  local dir="${1:-$PROJECT_DIR}"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then return; fi
  local out=""
  for f in CLAUDE.md AGENTS.md README.md; do
    if [ -f "$dir/$f" ]; then
      out+="## $f\n$(cat "$dir/$f")\n\n"
    fi
  done
  printf '%b' "$out"
}

# Build skills catalog JSON from SKILL.md frontmatter on disk.
# Returns a JSON array: [{id, name, description}, ...]
build_skills_catalog() {
  local skills_dir="${1:-skills}"
  if [ ! -d "$skills_dir" ]; then echo "[]"; return; fi
  python3 - "$skills_dir" <<'PY'
import json, os, sys, re
skills_dir = sys.argv[1]
catalog = []
for root, dirs, files in sorted(os.walk(skills_dir)):
    if "SKILL.md" not in files:
        continue
    skill_id = os.path.basename(root)
    path = os.path.join(root, "SKILL.md")
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except Exception as e:
        sys.stderr.write(f"Warning: {path}: {e}\n")
        continue
    # Parse YAML frontmatter between --- markers
    name, desc = skill_id, ""
    m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
    if m:
        for line in m.group(1).splitlines():
            if line.startswith("name:"):
                name = line.split(":", 1)[1].strip().strip("'\"")
            elif line.startswith("description:"):
                desc = line.split(":", 1)[1].strip().strip("'\"")
    catalog.append({"id": skill_id, "name": name, "description": desc})
print(json.dumps(catalog))
PY
}

build_skills_docs() {
  local skills_csv="$1"
  if [ -z "$skills_csv" ]; then return; fi

  local required_csv
  required_csv=$(config_get '.workflow.required_skills // [] | join(",")')
  local required_map=","
  if [ -n "$required_csv" ]; then
    required_map=",${required_csv},"
  fi

  local required_out=""
  local reference_out=""
  IFS=',' read -ra skills <<< "$skills_csv"
  for skill_id in "${skills[@]}"; do
    local skill_file
    local orch_skills="${ORCH_HOME:-$HOME/.orchestrator}/skills"
    skill_file=$(find skills/ "$orch_skills" -path "*/${skill_id}/SKILL.md" 2>/dev/null | head -1)
    if [ -n "$skill_file" ] && [ -f "$skill_file" ]; then
      if printf '%s' "$required_map" | grep -q ",${skill_id},"; then
        required_out+="### [REQUIRED] ${skill_id}\nYou MUST follow this skill's workflow exactly. Do not skip any steps.\n\n$(cat "$skill_file")\n\n"
      else
        reference_out+="### ${skill_id}\n$(cat "$skill_file")\n\n"
      fi
    fi
  done

  local out=""
  if [ -n "$required_out" ]; then
    out+="## Required Skills (MANDATORY — follow these workflows exactly)\n\n${required_out}"
  fi
  if [ -n "$reference_out" ]; then
    out+="## Reference Skills\n\n${reference_out}"
  fi
  printf '%b' "$out"
}

build_parent_context() {
  local task_id="$1"
  local parent_id
  parent_id=$(yq -r ".tasks[] | select(.id == $task_id) | .parent_id // \"\"" "$TASKS_PATH")
  if [ -z "$parent_id" ] || [ "$parent_id" = "null" ]; then return; fi

  local out=""
  local parent_title parent_summary
  parent_title=$(yq -r ".tasks[] | select(.id == $parent_id) | .title // \"\"" "$TASKS_PATH")
  parent_summary=$(yq -r ".tasks[] | select(.id == $parent_id) | .summary // \"\"" "$TASKS_PATH")

  if [ -n "$parent_title" ] && [ "$parent_title" != "null" ]; then
    out+="Parent task #${parent_id}: ${parent_title}\n"
    if [ -n "$parent_summary" ] && [ "$parent_summary" != "null" ]; then
      out+="Parent summary: ${parent_summary}\n"
    fi

    # Sibling summaries
    local siblings
    siblings=$(yq -r ".tasks[] | select(.parent_id == $parent_id and .id != $task_id) | \"\(.id): \(.title) [\(.status)]\"" "$TASKS_PATH" 2>/dev/null || true)
    if [ -n "$siblings" ]; then
      out+="\nSibling tasks:\n${siblings}\n"
    fi
  fi
  printf '%b' "$out"
}

build_git_diff() {
  local dir="${1:-$PROJECT_DIR}"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then return; fi
  (cd "$dir" && git diff --stat HEAD 2>/dev/null | head -50) || true
}

load_task() {
  local task_id="$1"
  local json
  json=$(yq -o=json -I=0 '.' "$TASKS_PATH")
  eval "$(printf '%s' "$json" | jq -r --argjson id "$task_id" '
    .tasks[] | select(.id == $id) |
    "export TASK_TITLE=" + (.title | @sh) +
    "\nexport TASK_BODY=" + (.body | @sh) +
    "\nexport TASK_LABELS=" + ((.labels // []) | join(",") | @sh) +
    "\nexport TASK_AGENT=" + (.agent // "" | @sh) +
    "\nexport AGENT_MODEL=" + (.agent_model // "" | @sh) +
    "\nexport TASK_COMPLEXITY=" + (.complexity // "medium" | @sh) +
    "\nexport AGENT_PROFILE_JSON=" + (.agent_profile // {} | tojson | @sh) +
    "\nexport ATTEMPTS=" + (.attempts // 0 | tostring | @sh) +
    "\nexport SELECTED_SKILLS=" + ((.selected_skills // []) | join(",") | @sh) +
    "\nexport TASK_PARENT_ID=" + (.parent_id // "" | tostring | @sh) +
    "\nexport GH_ISSUE_NUMBER=" + (.gh_issue_number // "" | tostring | @sh)
  ')"
  ROLE=$(printf '%s' "$AGENT_PROFILE_JSON" | jq -r '.role // "general"')
  export ROLE
}

# --- YQ helpers ---
# Read a single field from a task by ID
# Usage: task_field <id> <field>
# Example: task_field 3 .status  →  "done"
task_field() {
  local id="$1" field="$2"
  yq -r ".tasks[] | select(.id == $id) | $field" "$TASKS_PATH"
}

# Update task fields atomically (with lock)
# Usage: task_set <id> <field> <value>
# Example: task_set 3 .status "done"
# Example: task_set 3 .agent "claude"
task_set() {
  local id="$1" field="$2" value="$3"
  export _TS_VALUE="$value"
  with_lock yq -i "(.tasks[] | select(.id == $id) | $field) = strenv(_TS_VALUE)" "$TASKS_PATH"
  unset _TS_VALUE
}

# Count tasks matching a filter (uses dir_filter by default)
# Usage: task_count [status]
# Example: task_count "done"  →  5
#          task_count          →  12 (all)
task_count() {
  local status="${1:-}"
  local filter
  filter=$(dir_filter)
  if [ -n "$status" ]; then
    yq -r "[${filter} | select(.status == \"$status\")] | length" "$TASKS_PATH"
  else
    yq -r "[${filter}] | length" "$TASKS_PATH"
  fi
}

# List tasks as TSV rows for piping to table_with_header
# Usage: task_tsv <yq_fields_expr> [filter_expr]
# Example: task_tsv '[.id, .status, .title] | @tsv'
#          task_tsv '[.id, .title] | @tsv' 'select(.status == "new")'
task_tsv() {
  local fields="$1" extra_filter="${2:-}"
  local filter
  filter=$(dir_filter)
  if [ -n "$extra_filter" ]; then
    yq -r "${filter} | ${extra_filter} | ${fields}" "$TASKS_PATH"
  else
    yq -r "${filter} | ${fields}" "$TASKS_PATH"
  fi
}

dir_filter() {
  local project_dir="${PROJECT_DIR:-}"
  local orch_home="${ORCH_HOME:-$HOME/.orchestrator}"
  if [ -z "$project_dir" ] || [ "$project_dir" = "$orch_home" ]; then
    # No project context — show all tasks
    echo '.tasks[]'
  else
    # Filter to current project. The null/empty check handles pre-v0.1.0 tasks
    # that were created before the dir field existed.
    echo ".tasks[] | select(.dir == \"$project_dir\" or .dir == null or .dir == \"\")"
  fi
}

# Resolve the agent-specific model for a complexity level.
# Reads from config model_map; returns empty string if not configured.
# Usage: model_for_complexity "claude" "complex"  →  "opus"
model_for_complexity() {
  local agent="$1" complexity="$2"
  if [ -z "$complexity" ] || [ "$complexity" = "null" ]; then
    complexity="medium"
  fi
  config_get ".model_map.${complexity}.${agent} // \"\""
}

max_attempts() {
  local max
  max=$(config_get '.workflow.max_attempts // ""')
  if [ -z "$max" ] || [ "$max" = "null" ]; then
    echo "${MAX_ATTEMPTS:-10}"
  else
    echo "$max"
  fi
}

# Shared task creation — used by add_task.sh and run_task.sh delegations.
# Caller must hold the lock if calling inside a locked section.
# Args: id title body labels_csv [parent_id] [suggested_agent]
# Expects PROJECT_DIR and NOW in environment.
create_task_entry() {
  local id="$1" title="$2" body="$3" labels_csv="$4"
  local parent_id="${5:-}" suggested_agent="${6:-}"

  export id title body labels_csv parent_id suggested_agent
  local parent_expr="null"
  if [ -n "$parent_id" ]; then
    parent_expr="(env(parent_id) | tonumber)"
  fi

  yq -i \
    ".tasks += [{
      \"id\": (env(id) | tonumber),
      \"title\": strenv(title),
      \"body\": strenv(body),
      \"labels\": (strenv(labels_csv) | split(\",\") | map(select(length > 0))),
      \"status\": \"new\",
      \"agent\": (strenv(suggested_agent) | select(length > 0) // null),
      \"agent_model\": null,
      \"complexity\": null,
      \"agent_profile\": null,
      \"selected_skills\": [],
      \"parent_id\": ${parent_expr},
      \"children\": [],
      \"route_reason\": null,
      \"route_warning\": null,
      \"summary\": null,
      \"reason\": null,
      \"accomplished\": [],
      \"remaining\": [],
      \"blockers\": [],
      \"files_changed\": [],
      \"needs_help\": false,
      \"attempts\": 0,
      \"last_error\": null,
      \"prompt_hash\": null,
      \"last_comment_hash\": null,
      \"retry_at\": null,
      \"review_decision\": null,
      \"review_notes\": null,
      \"history\": [],
      \"dir\": strenv(PROJECT_DIR),
      \"created_at\": strenv(NOW),
      \"updated_at\": strenv(NOW),
      \"gh_last_feedback_at\": null
    }]" \
    "$TASKS_PATH"
}

# Simple spinner for long-running operations.
# Usage: start_spinner "message"; long_command; stop_spinner
SPINNER_PID=""
start_spinner() {
  local msg="${1:-Working}"
  if [ ! -t 2 ]; then return; fi  # skip if not a terminal
  (
    chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    i=0
    while true; do
      printf '\r\033[K  %s %s' "${chars:i%${#chars}:1}" "$msg" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [ -n "${SPINNER_PID:-}" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\033[K' >&2
  fi
}

# Post a comment on a linked GitHub issue.
# Usage: comment_on_issue TASK_ID "comment body"
# Requires GH_ISSUE_NUMBER and gh.repo in config. Silently skips if unavailable.
comment_on_issue() {
  local task_id="$1" body="$2"
  local issue_number="${GH_ISSUE_NUMBER:-}"
  if [ -z "$issue_number" ] || [ "$issue_number" = "null" ] || [ "$issue_number" = "0" ]; then
    return 0
  fi
  local repo
  repo=$(config_get '.gh.repo // ""')
  if [ -z "$repo" ] || [ "$repo" = "null" ]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  gh_api "repos/${repo}/issues/${issue_number}/comments" \
    -f body="$body" >/dev/null 2>&1 || true
}

# Add a label to a linked GitHub issue.
# Usage: label_issue TASK_ID "label"
label_issue() {
  local task_id="$1" label="$2"
  local issue_number="${GH_ISSUE_NUMBER:-}"
  if [ -z "$issue_number" ] || [ "$issue_number" = "null" ] || [ "$issue_number" = "0" ]; then
    return 0
  fi
  local repo
  repo=$(config_get '.gh.repo // ""')
  if [ -z "$repo" ] || [ "$repo" = "null" ]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  gh_api "repos/${repo}/issues/${issue_number}/labels" \
    --input - <<< "{\"labels\":[\"$label\"]}" >/dev/null 2>&1 || true
}

# Mark a task as needs_review — requires human attention.
# The task will not be retried until manually addressed.
# GitHub comments and labels are handled by gh_push.sh on next sync.
# Usage: mark_needs_review TASK_ID ATTEMPTS "error message" ["history note"]
mark_needs_review() {
  local task_id="$1" attempts="$2" error="$3" note="${4:-$3}"
  local now
  now=$(now_iso)
  export now
  with_lock yq -i \
    "(.tasks[] | select(.id == $task_id) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $task_id) | .last_error) = \"$error\" | \
     (.tasks[] | select(.id == $task_id) | .updated_at) = strenv(now)" \
    "$TASKS_PATH"
  append_history "$task_id" "needs_review" "$note"
}

fetch_issue_comments() {
  local repo="$1" issue_num="$2" max="${3:-10}"
  if [ -z "$issue_num" ] || [ "$issue_num" = "null" ] || [ "$issue_num" = "0" ]; then return 0; fi
  if [ -z "$repo" ] || [ "$repo" = "null" ]; then return 0; fi
  gh_api "repos/${repo}/issues/${issue_num}/comments" \
    -q ".[-${max}:] | .[] | \"### \" + .user.login + \" (\" + .created_at + \")\\n\" + .body + \"\\n---\"" 2>/dev/null || true
}

# Fetch issue/PR comments from the repo owner since a given timestamp.
# Returns JSON array of {login, created_at, body} objects.
# Usage: fetch_owner_feedback REPO ISSUE_NUM OWNER_LOGIN SINCE_TIMESTAMP
fetch_owner_feedback() {
  local repo="$1" issue_num="$2" owner_login="$3" since="${4:-}"
  if [ -z "$issue_num" ] || [ "$issue_num" = "null" ] || [ "$issue_num" = "0" ]; then echo "[]"; return 0; fi
  if [ -z "$repo" ] || [ "$repo" = "null" ]; then echo "[]"; return 0; fi
  if [ -z "$owner_login" ] || [ "$owner_login" = "null" ]; then echo "[]"; return 0; fi

  local api_url="repos/${repo}/issues/${issue_num}/comments"
  local since_param=""
  if [ -n "$since" ] && [ "$since" != "null" ]; then
    since_param="-f since=${since}"
  fi

  local raw
  # shellcheck disable=SC2086
  raw=$(gh_api -X GET "$api_url" $since_param 2>/dev/null) || { echo "[]"; return 0; }

  export _FOF_OWNER="$owner_login" _FOF_SINCE="${since:-}"
  printf '%s' "$raw" | yq -o=json -I=0 -p=json \
    '[.[] | select(.user.login == strenv(_FOF_OWNER) and (.body | test("via \[Orchestrator\]") | not) and (strenv(_FOF_SINCE) == "" or .created_at > strenv(_FOF_SINCE))) | {"login": .user.login, "created_at": .created_at, "body": .body}]' \
    2>/dev/null || echo "[]"
  unset _FOF_OWNER _FOF_SINCE
}

# Apply owner feedback to a task: append to context, reset status to routed.
# Caller must hold the lock (or pass from an unlocked context).
# Usage: process_owner_feedback TASK_ID FEEDBACK_JSON
process_owner_feedback() {
  local task_id="$1" feedback_json="$2"

  local count
  count=$(printf '%s' "$feedback_json" | yq -r 'length' 2>/dev/null || echo "0")
  if [ "$count" -le 0 ]; then return 0; fi

  # Build feedback text for context file
  local feedback_text=""
  local latest_ts=""
  for i in $(seq 0 $((count - 1))); do
    local login created_at body
    login=$(printf '%s' "$feedback_json" | yq -r ".[$i].login")
    created_at=$(printf '%s' "$feedback_json" | yq -r ".[$i].created_at")
    body=$(printf '%s' "$feedback_json" | yq -r ".[$i].body")
    feedback_text+="### Owner feedback from ${login} (${created_at})"$'\n'"${body}"$'\n---\n'
    latest_ts="$created_at"
  done

  # Append feedback to task context file
  append_task_context "$task_id" "$feedback_text"

  # Truncate for last_error (first 200 chars of combined feedback bodies)
  local combined_bodies
  combined_bodies=$(printf '%s' "$feedback_json" | yq -r '.[].body' | head -c 200)

  local now
  now=$(now_iso)
  export now combined_bodies latest_ts
  yq -i \
    "(.tasks[] | select(.id == $task_id) | .status) = \"routed\" |
     (.tasks[] | select(.id == $task_id) | .last_error) = strenv(combined_bodies) |
     (.tasks[] | select(.id == $task_id) | .needs_help) = false |
     (.tasks[] | select(.id == $task_id) | .gh_last_feedback_at) = strenv(latest_ts) |
     (.tasks[] | select(.id == $task_id) | .updated_at) = strenv(now)" \
    "$TASKS_PATH"

  local ts
  ts=$(now_iso)
  export ts
  export status="routed" note="owner feedback received"
  yq -i \
    "(.tasks[] | select(.id == $task_id) | .history) += [{\"ts\": strenv(ts), \"status\": strenv(status), \"note\": strenv(note)}]" \
    "$TASKS_PATH"
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
