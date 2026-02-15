#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/lib.sh"
require_yq
init_config_file
load_project_config

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
CONFIG_FILE="${PROJECT_DIR}/.orchestrator.yml"

REPO=${GITHUB_REPO:-$(config_get '.gh.repo // ""')}
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  REPO=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null \
    | sed -E 's#(https://github.com/|git@github.com:)##; s#\.git$##' || true)
fi
if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
  echo "No GitHub repo configured. Run 'orchestrator init' first or set gh.repo in .orchestrator.yml." >&2
  exit 1
fi

TITLE="${1:-$(basename "$PROJECT_DIR")}"

repo_owner=$(printf '%s' "$REPO" | cut -d'/' -f1)
owner_type=$(gh api "users/$repo_owner" -q .type 2>/dev/null || echo "User")

echo "Creating GitHub Project '$TITLE' for $REPO..."

if [ "$owner_type" = "Organization" ]; then
  create_json=$(gh api graphql \
    -f query='mutation($owner:ID!,$title:String!){ createProjectV2(input:{ownerId:$owner, title:$title}){ projectV2{ id number } } }' \
    -f owner="$(gh api "orgs/$repo_owner" -q .node_id)" \
    -f title="$TITLE")
else
  create_json=$(gh api graphql \
    -f query='mutation($owner:ID!,$title:String!){ createProjectV2(input:{ownerId:$owner, title:$title}){ projectV2{ id number } } }' \
    -f owner="$(gh api user -q .node_id)" \
    -f title="$TITLE")
fi

PROJECT_ID=$(printf '%s' "$create_json" | yq -r '.data.createProjectV2.projectV2.id // ""')
PROJECT_NUM=$(printf '%s' "$create_json" | yq -r '.data.createProjectV2.projectV2.number // ""')

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "Failed to create project." >&2
  printf '%s\n' "$create_json" >&2
  exit 1
fi

echo "Created project #$PROJECT_NUM: $TITLE"

# Link project to repository
link_project_to_repo "$PROJECT_ID" "$REPO"

# Save to config
export GH_PROJECT_ID="$PROJECT_ID"
if [ -f "$CONFIG_FILE" ]; then
  yq -i ".gh.project_id = env(GH_PROJECT_ID)" "$CONFIG_FILE"
else
  export REPO
  cat > "$CONFIG_FILE" <<YAML
gh:
  repo: "$REPO"
YAML
  yq -i ".gh.project_id = env(GH_PROJECT_ID)" "$CONFIG_FILE"
fi

# Auto-detect status field options
status_json=$(gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' -f project="$PROJECT_ID" 2>/dev/null || true)
if [ -n "$status_json" ]; then
  status_field_id=$(printf '%s' "$status_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null | head -n1)

  find_option_id() {
    local json="$1"; shift
    for name in "$@"; do
      local opt_id
      opt_id=$(printf '%s' "$json" | yq -r ".data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"^${name}$\"; \"i\")) | .id" 2>/dev/null | head -n1)
      if [ -n "$opt_id" ] && [ "$opt_id" != "null" ]; then
        echo "$opt_id"
        return
      fi
    done
  }

  backlog_id=$(find_option_id "$status_json" "Backlog" "Todo" "To Do" "New")
  inprog_id=$(find_option_id "$status_json" "In Progress" "In progress" "Doing" "Active" "Working")
  review_id=$(find_option_id "$status_json" "Review" "In Review" "Needs Review")
  done_id=$(find_option_id "$status_json" "Done" "Completed" "Closed" "Finished")

  export status_field_id backlog_id inprog_id review_id done_id
  if [ -n "$status_field_id" ] && [ "$status_field_id" != "null" ]; then
    yq -i ".gh.project_status_field_id = env(status_field_id)" "$CONFIG_FILE"
  fi
  [ -n "${backlog_id:-}" ] && [ "$backlog_id" != "null" ] && yq -i '.gh.project_status_map.backlog = env(backlog_id)' "$CONFIG_FILE"
  [ -n "${inprog_id:-}" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_map.in_progress = env(inprog_id)' "$CONFIG_FILE"
  [ -n "${review_id:-}" ] && [ "$review_id" != "null" ] && yq -i '.gh.project_status_map.review = env(review_id)' "$CONFIG_FILE"
  [ -n "${done_id:-}" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_map.done = env(done_id)' "$CONFIG_FILE"

  echo "Detected status options:"
  [ -n "${backlog_id:-}" ] && echo "  backlog -> $backlog_id" || echo "  backlog -> (not found)"
  [ -n "${inprog_id:-}" ] && echo "  in_progress -> $inprog_id" || echo "  in_progress -> (not found)"
  [ -n "${review_id:-}" ] && echo "  review -> $review_id" || echo "  review -> (not found)"
  [ -n "${done_id:-}" ] && echo "  done -> $done_id" || echo "  done -> (not found)"
fi

echo ""
echo "Project ID: $PROJECT_ID"

# Auto-add guidance
if [ "$owner_type" = "Organization" ]; then
  workflows_url="https://github.com/orgs/$repo_owner/projects/$PROJECT_NUM/workflows"
else
  workflows_url="https://github.com/users/$repo_owner/projects/$PROJECT_NUM/workflows"
fi
echo ""
echo "To enable auto-add (new issues -> project), visit:"
echo "  $workflows_url"
echo "and enable 'Auto-add to project' for this repo."
