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

PROJECT_ID=${GITHUB_PROJECT_ID:-$(config_get '.gh.project_id // ""')}
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "Missing gh.project_id. Set it in config.yml or export GITHUB_PROJECT_ID." >&2
  exit 1
fi

FIELDS_JSON=$(gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' -f project="$PROJECT_ID")

STATUS_FIELD_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' | head -n1)
BACKLOG_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == "Backlog") | .id' | head -n1)
INPROG_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == "In progress") | .id' | head -n1)
REVIEW_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == "In review") | .id' | head -n1)
DONE_ID=$(printf '%s' "$FIELDS_JSON" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == "Done") | .id' | head -n1)

if [ -z "$STATUS_FIELD_ID" ] || [ "$STATUS_FIELD_ID" = "null" ]; then
  echo "Status field not found in project." >&2
  exit 1
fi

export STATUS_FIELD_ID BACKLOG_ID INPROG_ID REVIEW_ID DONE_ID
yq -i \
  ".gh.project_status_field_id = env(STATUS_FIELD_ID) | \
   .gh.project_status_map.backlog = env(BACKLOG_ID) | \
   .gh.project_status_map.in_progress = env(INPROG_ID) | \
   .gh.project_status_map.review = env(REVIEW_ID) | \
   .gh.project_status_map.done = env(DONE_ID)" \
  "$CONFIG_PATH"

echo "Applied Status field and option IDs to config.yml"
