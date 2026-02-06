#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_config_file

TASK_ID=${1:-}
if [ -z "$TASK_ID" ]; then
  TASK_ID=$(yq -r '.tasks[] | select(.status == "new") | .id' "$TASKS_PATH" | head -n1)
  if [ -z "$TASK_ID" ]; then
    echo "No new tasks to route" >&2
    exit 1
  fi
fi

TASK_TITLE=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .title" "$TASKS_PATH")
TASK_BODY=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .body" "$TASKS_PATH")
TASK_LABELS=$(yq -r ".tasks[] | select(.id == $TASK_ID) | .labels | join(\",\")" "$TASKS_PATH")
ROUTER_AGENT=${ROUTER_AGENT:-$(config_get '.router.agent // "claude"')}
ROUTER_MODEL=${ROUTER_MODEL:-$(config_get '.router.model // ""')}
ALLOWED_TOOLS_CSV=$(config_get '.router.allowed_tools // [] | join(",")')
DEFAULT_SKILLS_CSV=$(config_get '.router.default_skills // [] | join(",")')

if [ -z "$TASK_TITLE" ] || [ "$TASK_TITLE" = "null" ]; then
  echo "Task $TASK_ID not found" >&2
  exit 1
fi

SKILLS_CATALOG=""
if [ -f "skills.yml" ]; then
  SKILLS_CATALOG=$(cat "skills.yml")
fi

PROMPT=$(render_template "prompts/route.md" "$TASK_ID" "$TASK_TITLE" "$TASK_LABELS" "$TASK_BODY" "{}" "" "" "$SKILLS_CATALOG")

case "$ROUTER_AGENT" in
  codex)
    if [ -n "$ROUTER_MODEL" ]; then
      RESPONSE=$(codex --model "$ROUTER_MODEL" --print "$PROMPT")
    else
      RESPONSE=$(codex --print "$PROMPT")
    fi
    ;;
  claude)
    if [ -n "$ROUTER_MODEL" ]; then
      RESPONSE=$(claude --model "$ROUTER_MODEL" --print "$PROMPT")
    else
      RESPONSE=$(claude --print "$PROMPT")
    fi
    ;;
  *)
    echo "Unknown router agent: $ROUTER_AGENT" >&2
    exit 1
    ;;
 esac

ROUTED_AGENT=$(printf '%s' "$RESPONSE" | yq -r '.executor')
REASON=$(printf '%s' "$RESPONSE" | yq -r '.reason')
PROFILE_YAML=$(printf '%s' "$RESPONSE" | yq '.profile // {}')
SELECTED_SKILLS_CSV=$(printf '%s' "$RESPONSE" | yq -r '.selected_skills // [] | join(",")')
MODEL=$(printf '%s' "$RESPONSE" | yq -r '.model // ""')
NOW=$(now_iso)

# Apply static defaults
if [ -n "$ALLOWED_TOOLS_CSV" ]; then
  PROFILE_YAML=$(printf '%s' "$PROFILE_YAML" | yq ".tools = (\"$ALLOWED_TOOLS_CSV\" | split(\",\") | map(select(length > 0)))")
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
SKILLS=$(printf '%s' "$PROFILE_YAML" | yq -r '.skills // [] | join(",")')
SKILLS_LOWER=$(printf '%s' "$SKILLS" | tr '[:upper:]' '[:lower:]')

if echo "$LABELS_LOWER" | grep -qE '(backend|api|database|db)'; then
  if [ "$ROUTED_AGENT" = "claude" ]; then
    ROUTE_WARNING="backend-labeled task routed to claude"
  fi
fi

if echo "$LABELS_LOWER" | grep -qE '(docs|documentation|writing)'; then
  if [ "$ROUTED_AGENT" = "codex" ]; then
    ROUTE_WARNING="docs-labeled task routed to codex"
  fi
fi

if [ -z "$SKILLS_LOWER" ]; then
  ROUTE_WARNING="profile missing skills"
fi

TMP_PROFILE=$(mktemp)
printf '%s
' "$PROFILE_YAML" > "$TMP_PROFILE"

ROLE=$(printf '%s' "$PROFILE_YAML" | yq -r '.role // "general"')
AGENT_LABEL="agent:${ROUTED_AGENT}"
ROLE_LABEL="role:${ROLE}"
MODEL_LABEL=""
if [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
  MODEL_LABEL="model:${MODEL}"
fi

export ROUTED_AGENT REASON NOW ROUTE_WARNING AGENT_LABEL ROLE_LABEL SELECTED_SKILLS_CSV MODEL MODEL_LABEL

with_lock yq -i \
  "(.tasks[] | select(.id == $TASK_ID) | .agent) = env(ROUTED_AGENT) | \
   (.tasks[] | select(.id == $TASK_ID) | .agent_model) = (env(MODEL) | select(length > 0) // null) | \
   (.tasks[] | select(.id == $TASK_ID) | .status) = \"routed\" | \
   (.tasks[] | select(.id == $TASK_ID) | .route_reason) = env(REASON) | \
   (.tasks[] | select(.id == $TASK_ID) | .route_warning) = (env(ROUTE_WARNING) | select(length > 0) // null) | \
   (.tasks[] | select(.id == $TASK_ID) | .agent_profile) = load(\"$TMP_PROFILE\") | \
   (.tasks[] | select(.id == $TASK_ID) | .selected_skills) = (env(SELECTED_SKILLS_CSV) | split(\",\") | map(select(length > 0)) | unique) | \
   (.tasks[] | select(.id == $TASK_ID) | .labels) |= ((. + [env(AGENT_LABEL), env(ROLE_LABEL)] + (env(MODEL_LABEL) | select(length > 0) | [.] // [])) | unique) | \
   (.tasks[] | select(.id == $TASK_ID) | .updated_at) = env(NOW)" \
  "$TASKS_PATH"

rm -f "$TMP_PROFILE"

NOTE="routed to $ROUTED_AGENT"
if [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
  NOTE="$NOTE (model: $MODEL)"
fi
if [ -n "$ROUTE_WARNING" ]; then
  NOTE="$NOTE (warning: $ROUTE_WARNING)"
fi
append_history "$TASK_ID" "routed" "$NOTE"

echo "$ROUTED_AGENT"
