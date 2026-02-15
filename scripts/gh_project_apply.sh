#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh
init_config_file
load_project_config

PROJECT_ID=${GITHUB_PROJECT_ID:-$(config_get '.gh.project_id // ""')}
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "Missing gh.project_id. Set it in config.yml or export GITHUB_PROJECT_ID." >&2
  exit 1
fi

FIELDS_JSON=$(gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' -f project="$PROJECT_ID")

STATUS_FIELD_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' | head -n1)

if [ -z "$STATUS_FIELD_ID" ] || [ "$STATUS_FIELD_ID" = "null" ]; then
  echo "Status field not found in project." >&2
  exit 1
fi

# Helper: find option ID matching any of the given names (case-insensitive)
find_option_id() {
  local json="$1"; shift
  for name in "$@"; do
    local id
    id=$(printf '%s' "$json" | yq -r ".data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"^${name}$\"; \"i\")) | .id" 2>/dev/null | head -n1)
    if [ -n "$id" ] && [ "$id" != "null" ]; then
      echo "$id"
      return
    fi
  done
}

BACKLOG_ID=$(find_option_id "$FIELDS_JSON" "Backlog" "Todo" "To Do" "New")
INPROG_ID=$(find_option_id "$FIELDS_JSON" "In Progress" "In progress" "Doing" "Active" "Working")
REVIEW_ID=$(find_option_id "$FIELDS_JSON" "Review" "In Review" "In review" "Needs Review")
DONE_ID=$(find_option_id "$FIELDS_JSON" "Done" "Completed" "Closed" "Finished")

export STATUS_FIELD_ID
yq -i ".gh.project_status_field_id = strenv(STATUS_FIELD_ID)" "$GLOBAL_CONFIG_PATH"

export BACKLOG_ID INPROG_ID REVIEW_ID DONE_ID
[ -n "$BACKLOG_ID" ] && [ "$BACKLOG_ID" != "null" ] && yq -i '.gh.project_status_map.backlog = strenv(BACKLOG_ID)' "$GLOBAL_CONFIG_PATH"
[ -n "$INPROG_ID" ] && [ "$INPROG_ID" != "null" ] && yq -i '.gh.project_status_map.in_progress = strenv(INPROG_ID)' "$GLOBAL_CONFIG_PATH"
[ -n "$REVIEW_ID" ] && [ "$REVIEW_ID" != "null" ] && yq -i '.gh.project_status_map.review = strenv(REVIEW_ID)' "$GLOBAL_CONFIG_PATH"
[ -n "$DONE_ID" ] && [ "$DONE_ID" != "null" ] && yq -i '.gh.project_status_map.done = strenv(DONE_ID)' "$GLOBAL_CONFIG_PATH"

echo "Applied Status field and option IDs to config.yml"
