#!/usr/bin/env bash
# shellcheck source=scripts/lib.sh
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
require_yq
require_jq
require_rg
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
init_config_file
load_project_config

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    log_err "No new tasks to route"
    exit 1
  fi
fi

log_err "[route] task=$TASK_ID starting"
mkdir -p .orchestrator
CMD_STATUS=0
ROUTED_AGENT=""
TMP_PROFILE=""
trap 'rm -f "$TMP_PROFILE"' EXIT

TASK_TITLE=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .title" "$TASKS_PATH")
TASK_BODY=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .body" "$TASKS_PATH")
TASK_LABELS=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .labels | join(\",\")" "$TASKS_PATH")
ROUTER_AGENT=${ROUTER_AGENT:-$(config_get '.router.agent // "claude"')}
ROUTER_MODEL=${ROUTER_MODEL:-$(config_get '.router.model // ""')}
ROUTER_TIMEOUT=${ROUTER_TIMEOUT:-$(config_get '.router.timeout_seconds // ""')}
ROUTER_FALLBACK=${ROUTER_FALLBACK:-$(config_get '.router.fallback_executor // "codex"')}
ALLOWED_TOOLS_CSV=$(config_get '.router.allowed_tools // [] | join(",")')
DEFAULT_SKILLS_CSV=$(config_get '.router.default_skills // [] | join(",")')

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  log_err "Task $TASK_ID not found"
  exit 1
fi

SKILLS_CATALOG=""
if [ -f "skills.yml" ]; then
  SKILLS_CATALOG=$(yq -o=json -I=0 '.skills // []' "skills.yml")
fi
# If catalog is empty, auto-build from SKILL.md files on disk
if [ -z "$SKILLS_CATALOG" ] || [ "$SKILLS_CATALOG" = "[]" ] || [ "$SKILLS_CATALOG" = "null" ]; then
  ORCH_SKILLS="${ORCH_HOME:-$HOME/.orchestrator}/skills"
  if [ -d "$ORCH_SKILLS" ]; then
    SKILLS_CATALOG=$(build_skills_catalog "$ORCH_SKILLS")
  elif [ -d "skills" ]; then
    SKILLS_CATALOG=$(build_skills_catalog "skills")
  fi
fi

AVAILABLE_AGENTS=$(available_agents)
if [ -z "$AVAILABLE_AGENTS" ]; then
  log_err "No agent CLIs found in PATH."
  exit 1
fi

export TASK_ID TASK_TITLE TASK_LABELS TASK_BODY SKILLS_CATALOG AVAILABLE_AGENTS
PROMPT=$(render_template "$SCRIPT_DIR/../prompts/route.md")
PROMPT_FILE=".orchestrator/route-prompt-${TASK_ID}.txt"
printf '%s' "$PROMPT" > "$PROMPT_FILE"

require_agent "$ROUTER_AGENT"

run_router_cmd() {
  if [ -n "${ROUTER_TIMEOUT:-}" ] && [ "${ROUTER_TIMEOUT}" != "0" ]; then
    AGENT_TIMEOUT_SECONDS="${ROUTER_TIMEOUT}" run_with_timeout "$@"
    return $?
  fi
  "$@"
}

start_spinner "Routing task $TASK_ID"

case "$ROUTER_AGENT" in
  codex)
    log_err "[route] using codex model=${ROUTER_MODEL:-default}"
    log_err "[route] timeout=${ROUTER_TIMEOUT:-${AGENT_TIMEOUT_SECONDS:-900}}s"
    log_err "[route] cmd: codex exec --json ${ROUTER_MODEL:+--model \"$ROUTER_MODEL\"} \"$(cat "$PROMPT_FILE")\""
    if [ -n "$ROUTER_MODEL" ]; then
      RESPONSE=$(run_router_cmd codex exec --model "$ROUTER_MODEL" --json "$PROMPT") || CMD_STATUS=$?
    else
      RESPONSE=$(run_router_cmd codex exec --json "$PROMPT") || CMD_STATUS=$?
    fi
    ;;
  claude)
    log_err "[route] using claude model=${ROUTER_MODEL:-default}"
    log_err "[route] timeout=${ROUTER_TIMEOUT:-${AGENT_TIMEOUT_SECONDS:-900}}s"
    log_err "[route] cmd: claude ${ROUTER_MODEL:+--model \"$ROUTER_MODEL\"} --output-format json --print \"$(cat "$PROMPT_FILE")\""
    if [ -n "$ROUTER_MODEL" ]; then
      RESPONSE=$(run_router_cmd claude --model "$ROUTER_MODEL" --output-format json --print "$PROMPT") || CMD_STATUS=$?
    else
      RESPONSE=$(run_router_cmd claude --output-format json --print "$PROMPT") || CMD_STATUS=$?
    fi
    ;;
  opencode)
    log_err "[route] using opencode"
    log_err "[route] timeout=${ROUTER_TIMEOUT:-${AGENT_TIMEOUT_SECONDS:-900}}s"
    log_err "[route] cmd: opencode run --format json \"$(cat "$PROMPT_FILE")\""
    RESPONSE=$(run_router_cmd opencode run --format json "$PROMPT") || CMD_STATUS=$?
    ;;
  *)
    log_err "[route] unknown router agent: $ROUTER_AGENT"
    exit 1
    ;;
esac

stop_spinner
log_err "[route] raw response:"
printf '%s\n' "$RESPONSE" | sed 's/^/[route] > /' >&2

if [ "${CMD_STATUS:-0}" -ne 0 ]; then
  log_err "[route] router failed exit=${CMD_STATUS}"
  if [ -n "${ROUTER_FALLBACK:-}" ]; then
    if command -v "$ROUTER_FALLBACK" >/dev/null 2>&1; then
      ROUTED_AGENT="$ROUTER_FALLBACK"
    else
      ROUTED_AGENT=$(printf '%s' "$AVAILABLE_AGENTS" | cut -d',' -f1)
    fi
    REASON="router failed (exit $CMD_STATUS); fallback to $ROUTED_AGENT"
    ROUTE_WARNING=""
    PROFILE_JSON='{}'
    SELECTED_SKILLS_CSV=""
    COMPLEXITY="medium"
    NOW=$(now_iso)
    # Apply static defaults to fallback profile
    if [ -n "$ALLOWED_TOOLS_CSV" ]; then
      PROFILE_JSON=$(printf '%s' "$PROFILE_JSON" | jq -c --arg tools "$ALLOWED_TOOLS_CSV" '.tools = ($tools | split(",") | map(select(length > 0)))')
    fi
    TMP_PROFILE=$(mktemp)
    printf '%s
' "$PROFILE_JSON" > "$TMP_PROFILE"
    ROLE="general"
    AGENT_LABEL="agent:${ROUTED_AGENT}"
    ROLE_LABEL="role:${ROLE}"
    COMPLEXITY_LABEL="complexity:${COMPLEXITY}"
    export ROUTED_AGENT REASON NOW ROUTE_WARNING AGENT_LABEL ROLE_LABEL SELECTED_SKILLS_CSV COMPLEXITY COMPLEXITY_LABEL
    with_lock yq -i \
      "(.tasks[] | select(.id == $TASK_ID) | .agent) = (strenv(ROUTED_AGENT) | select(length > 0)) | \
       (.tasks[] | select(.id == $TASK_ID) | .complexity) = strenv(COMPLEXITY) | \
       (.tasks[] | select(.id == $TASK_ID) | .status) = \"routed\" | \
       (.tasks[] | select(.id == $TASK_ID) | .route_reason) = strenv(REASON) | \
       (.tasks[] | select(.id == $TASK_ID) | .route_warning) = (strenv(ROUTE_WARNING) | select(length > 0) // null) | \
       (.tasks[] | select(.id == $TASK_ID) | .agent_profile) = load(\"$TMP_PROFILE\") | \
       (.tasks[] | select(.id == $TASK_ID) | .selected_skills) = (strenv(SELECTED_SKILLS_CSV) | split(\",\") | map(select(length > 0)) | unique) | \
       (.tasks[] | select(.id == $TASK_ID) | .labels) |= ((. + [strenv(AGENT_LABEL), strenv(ROLE_LABEL), strenv(COMPLEXITY_LABEL)]) | unique) | \
       (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
      "$TASKS_PATH"
    append_history "$TASK_ID" "routed" "$REASON"
    log_err "[route] task=$TASK_ID fallback to ${ROUTED_AGENT}"
    echo "$ROUTED_AGENT"
    exit 0
  fi

  NOW=$(now_iso)
  export NOW
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"router failed (exit ${CMD_STATUS})\" | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
    "$TASKS_PATH"
  append_history "$TASK_ID" "needs_review" "router failed (exit ${CMD_STATUS})"
  exit 0
fi

RESPONSE_JSON=$(normalize_json_response "$RESPONSE" 2>/dev/null || true)
if [ -z "$RESPONSE_JSON" ] || ! printf '%s' "$RESPONSE_JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
  log_err "[route] invalid JSON response"
  NOW=$(now_iso)
  export NOW
  with_lock yq -i \
    "(.tasks[] | select(.id == $TASK_ID) | .status) = \"needs_review\" | \
     (.tasks[] | select(.id == $TASK_ID) | .last_error) = \"router response invalid JSON\" | \
     (.tasks[] | select(.id == $TASK_ID) | .summary) = \"Router error: invalid JSON response\" | \
     (.tasks[] | select(.id == $TASK_ID) | .blockers) = [\"Router failed to return valid JSON\"] | \
     (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
    "$TASKS_PATH"
  mkdir -p "$CONTEXTS_DIR"
  printf '%s' "$RESPONSE" > "${CONTEXTS_DIR}/route-response-${TASK_ID}.md"
  append_history "$TASK_ID" "needs_review" "router response invalid JSON"
  exit 0
fi

ROUTED_AGENT=$(printf '%s' "$RESPONSE_JSON" | jq -r '.executor // ""')
REASON=$(printf '%s' "$RESPONSE_JSON" | jq -r '.reason // ""')
PROFILE_JSON=$(printf '%s' "$RESPONSE_JSON" | jq -c '.profile // {}')
SELECTED_SKILLS_CSV=$(printf '%s' "$RESPONSE_JSON" | jq -r '.selected_skills // [] | join(",")')
COMPLEXITY=$(printf '%s' "$RESPONSE_JSON" | jq -r '.complexity // "medium"')
NOW=$(now_iso)

# Validate routed agent is installed
if [ -n "$ROUTED_AGENT" ] && ! command -v "$ROUTED_AGENT" >/dev/null 2>&1; then
  FIRST_AVAILABLE=$(printf '%s' "$AVAILABLE_AGENTS" | cut -d',' -f1)
  log_err "[route] $ROUTED_AGENT not installed, falling back to $FIRST_AVAILABLE"
  REASON="$REASON (router picked $ROUTED_AGENT but not installed; using $FIRST_AVAILABLE)"
  ROUTED_AGENT="$FIRST_AVAILABLE"
fi

# Apply static defaults
if [ -n "$ALLOWED_TOOLS_CSV" ]; then
  PROFILE_JSON=$(printf '%s' "$PROFILE_JSON" | jq -c --arg tools "$ALLOWED_TOOLS_CSV" '.tools = ($tools | split(",") | map(select(length > 0)))')
fi
if [ -n "$DEFAULT_SKILLS_CSV" ]; then
  if [ -n "$SELECTED_SKILLS_CSV" ]; then
    SELECTED_SKILLS_CSV="$SELECTED_SKILLS_CSV,$DEFAULT_SKILLS_CSV"
  else
    SELECTED_SKILLS_CSV="$DEFAULT_SKILLS_CSV"
  fi
fi

# Simple router sanity check
ROUTE_WARNING=""
LABELS_LOWER=$(printf '%s' "$TASK_LABELS" | tr '[:upper:]' '[:lower:]')
SKILLS=$(printf '%s' "$PROFILE_JSON" | jq -r '.skills // [] | join(",")')
SKILLS_LOWER=$(printf '%s' "$SKILLS" | tr '[:upper:]' '[:lower:]')

if printf '%s' "$LABELS_LOWER" | rg -q '(backend|api|database|db)'; then
  if [ "$ROUTED_AGENT" = "claude" ]; then
    ROUTE_WARNING="backend-labeled task routed to claude"
  fi
fi

if printf '%s' "$LABELS_LOWER" | rg -q '(docs|documentation|writing)'; then
  if [ "$ROUTED_AGENT" = "codex" ]; then
    ROUTE_WARNING="docs-labeled task routed to codex"
  fi
fi

if [ -z "$SKILLS_LOWER" ]; then
  ROUTE_WARNING="profile missing skills"
fi

TMP_PROFILE=$(mktemp)
printf '%s
' "$PROFILE_JSON" > "$TMP_PROFILE"

ROLE=$(printf '%s' "$PROFILE_JSON" | jq -r '.role // "general"')
AGENT_LABEL="agent:${ROUTED_AGENT}"
ROLE_LABEL="role:${ROLE}"
COMPLEXITY_LABEL="complexity:${COMPLEXITY}"

# Decompose: manual "plan" label
DECOMPOSE_LABEL=""
if printf '%s' "$LABELS_LOWER" | rg -q '(^|,)plan(,|$)'; then
  DECOMPOSE_LABEL="plan"
fi

export ROUTED_AGENT REASON NOW ROUTE_WARNING AGENT_LABEL ROLE_LABEL SELECTED_SKILLS_CSV COMPLEXITY COMPLEXITY_LABEL DECOMPOSE_LABEL

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .agent) = (strenv(ROUTED_AGENT) | select(length > 0)) | \
   (.tasks[] | select(.id == $TASK_ID) | .complexity) = strenv(COMPLEXITY) | \
   (.tasks[] | select(.id == $TASK_ID) | .status) = \"routed\" | \
   (.tasks[] | select(.id == $TASK_ID) | .route_reason) = strenv(REASON) | \
   (.tasks[] | select(.id == $TASK_ID) | .route_warning) = (strenv(ROUTE_WARNING) | select(length > 0) // null) | \
   (.tasks[] | select(.id == $TASK_ID) | .agent_profile) = load(\"$TMP_PROFILE\") | \
   (.tasks[] | select(.id == $TASK_ID) | .selected_skills) = (strenv(SELECTED_SKILLS_CSV) | split(\",\") | map(select(length > 0)) | unique) | \
   (.tasks[] | select(.id == $TASK_ID) | .labels) |= ((. + [strenv(AGENT_LABEL), strenv(ROLE_LABEL), strenv(COMPLEXITY_LABEL)] + (strenv(DECOMPOSE_LABEL) | select(length > 0) | [.] // [])) | unique) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = strenv(NOW)" \
  "$TASKS_PATH"

NOTE="routed to $ROUTED_AGENT (complexity: $COMPLEXITY)"
if [ -n "$ROUTE_WARNING" ]; then
  NOTE="$NOTE (warning: $ROUTE_WARNING)"
fi
append_history "$TASK_ID" "routed" "$NOTE"

log_err "[route] task=$TASK_ID routed to ${ROUTED_AGENT:-unknown}"

echo "$ROUTED_AGENT"
