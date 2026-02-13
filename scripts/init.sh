#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR=${PROJECT_DIR:-$(pwd)}

# Non-interactive mode via flags or env vars
GH_REPO="${ORCH_GH_REPO:-}"
GH_PROJECT_ID="${ORCH_GH_PROJECT_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       GH_REPO="$2"; shift 2 ;;
    --project-id) GH_PROJECT_ID="$2"; shift 2 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "Initialized orchestrator for $(basename "$PROJECT_DIR")"
echo "  Project: $PROJECT_DIR"

write_config() {
  local config_file="$PROJECT_DIR/.orchestrator.yml"
  if [ -z "$GH_REPO" ]; then return; fi
  export GH_REPO
  if [ -f "$config_file" ]; then
    yq -i ".gh.repo = env(GH_REPO)" "$config_file"
  else
    cat > "$config_file" <<YAML
gh:
  repo: "$GH_REPO"
YAML
  fi
  echo "Created .orchestrator.yml"

  if [ -n "$GH_PROJECT_ID" ]; then
    export GH_PROJECT_ID
    yq -i ".gh.project_id = env(GH_PROJECT_ID)" "$config_file"
  fi

  # Auto-detect status field if gh is available and project_id is set
  local project_id="${GH_PROJECT_ID:-}"
  if [ -z "$project_id" ]; then
    project_id=$(yq -r '.gh.project_id // ""' "$config_file" 2>/dev/null || true)
  fi
  if [ -n "$project_id" ] && [ "$project_id" != "null" ] && command -v gh >/dev/null 2>&1; then
    auto_detect_status "$config_file" "$project_id"
  fi
}

auto_detect_status() {
  local config_file="$1" project_id="$2"
  local status_json
  status_json=$(gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' -f project="$project_id" 2>/dev/null || true)
  [ -n "$status_json" ] || return 0

  local status_field_id
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

  local backlog_id inprog_id review_id done_id
  backlog_id=$(find_option_id "$status_json" "Backlog" "Todo" "To Do" "New")
  inprog_id=$(find_option_id "$status_json" "In Progress" "In progress" "Doing" "Active" "Working")
  review_id=$(find_option_id "$status_json" "Review" "In Review" "Needs Review")
  done_id=$(find_option_id "$status_json" "Done" "Completed" "Closed" "Finished")

  export status_field_id backlog_id inprog_id review_id done_id
  if [ -n "$status_field_id" ] && [ "$status_field_id" != "null" ]; then
    yq -i ".gh.project_status_field_id = env(status_field_id)" "$config_file"
  fi
  [ -n "$backlog_id" ] && [ "$backlog_id" != "null" ] && yq -i '.gh.project_status_map.backlog = env(backlog_id)' "$config_file"
  [ -n "$inprog_id" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_map.in_progress = env(inprog_id)' "$config_file"
  [ -n "$review_id" ] && [ "$review_id" != "null" ] && yq -i '.gh.project_status_map.review = env(review_id)' "$config_file"
  [ -n "$done_id" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_map.done = env(done_id)' "$config_file"

  echo "Detected status options:"
  [ -n "$backlog_id" ] && echo "  backlog -> $backlog_id" || echo "  backlog -> (not found)"
  [ -n "$inprog_id" ] && echo "  in_progress -> $inprog_id" || echo "  in_progress -> (not found)"
  [ -n "$review_id" ] && echo "  review -> $review_id" || echo "  review -> (not found)"
  [ -n "$done_id" ] && echo "  done -> $done_id" || echo "  done -> (not found)"
}

# Non-interactive: flags/env provided
if [ -n "$GH_REPO" ]; then
  write_config
# Interactive: terminal attached
elif [ -t 0 ]; then
  read -r -p "Configure GitHub integration? (y/N): " SETUP_GH
  if [ "$SETUP_GH" = "y" ] || [ "$SETUP_GH" = "Y" ]; then
    read -r -p "GitHub repo (owner/repo): " GH_REPO
    if [ -n "$GH_REPO" ]; then
      CONFIG_FILE="$PROJECT_DIR/.orchestrator.yml"
      write_config

      # Interactive project selection if gh available and no project yet
      if command -v gh >/dev/null 2>&1 && [ -z "$GH_PROJECT_ID" ]; then
        read -r -p "GitHub Project ID [auto-detect if blank]: " GH_PROJECT_ID_INPUT

        if [ -z "$GH_PROJECT_ID_INPUT" ]; then
          user_login=$(gh api user -q .login 2>/dev/null || true)
          orgs=$(gh api user/orgs -q '.[].login' 2>/dev/null || true)

          projects=()
          ids=()

          if [ -n "$user_login" ]; then
            user_json=$(gh api graphql -f query='query($user:String!){ user(login:$user){ projectsV2(first:100){ nodes{ id number title } } } }' -f user="$user_login" 2>/dev/null || true)
            if [ -n "$user_json" ]; then
              while IFS=$'\t' read -r number title id; do
                [ -n "$id" ] || continue
                projects+=("user:${user_login} #${number} ${title}")
                ids+=("$id")
              done < <(printf '%s' "$user_json" | yq -r '.data.user.projectsV2.nodes[] | [.number, .title, .id] | @tsv' 2>/dev/null)
            fi
          fi

          if [ -n "$orgs" ]; then
            while IFS= read -r org; do
              [ -n "$org" ] || continue
              org_json=$(gh api graphql -f query='query($org:String!){ organization(login:$org){ projectsV2(first:100){ nodes{ id number title } } } }' -f org="$org" 2>/dev/null || true)
              if [ -n "$org_json" ]; then
                while IFS=$'\t' read -r number title id; do
                  [ -n "$id" ] || continue
                  projects+=("org:${org} #${number} ${title}")
                  ids+=("$id")
                done < <(printf '%s' "$org_json" | yq -r '.data.organization.projectsV2.nodes[] | [.number, .title, .id] | @tsv' 2>/dev/null)
              fi
            done <<< "$orgs"
          fi

          if [ ${#projects[@]} -gt 0 ]; then
            echo "Detected GitHub Projects:"
            i=1
            for p in "${projects[@]}"; do
              echo "  [$i] $p"
              i=$((i + 1))
            done
            read -r -p "Select project number to use [skip]: " selection
            if [ -n "$selection" ] && [[ "$selection" =~ ^[0-9]+$ ]]; then
              idx=$((selection - 1))
              if [ $idx -ge 0 ] && [ $idx -lt ${#ids[@]} ]; then
                GH_PROJECT_ID_INPUT="${ids[$idx]}"
              fi
            fi
          fi
        fi

        if [ -n "${GH_PROJECT_ID_INPUT:-}" ]; then
          GH_PROJECT_ID="$GH_PROJECT_ID_INPUT"
          export GH_PROJECT_ID
          yq -i ".gh.project_id = env(GH_PROJECT_ID)" "$CONFIG_FILE"
          auto_detect_status "$CONFIG_FILE" "$GH_PROJECT_ID"
        fi
      fi
    fi
  fi
fi

echo ""
echo "Add tasks with: orchestrator add \"title\" \"body\" \"labels\""
echo "Start the server: orchestrator serve"
