#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=${PROJECT_DIR:-$(pwd)}

# Non-interactive mode via flags or env vars
GH_REPO="${ORCH_GH_REPO:-}"
GH_PROJECT_ID="${ORCH_GH_PROJECT_ID:-}"
FLAG_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       GH_REPO="$2"; FLAG_MODE=true; shift 2 ;;
    --project-id) GH_PROJECT_ID="$2"; FLAG_MODE=true; shift 2 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CONFIG_FILE="$PROJECT_DIR/.orchestrator.yml"

# Load existing config if present (idempotent re-init)
EXISTING_REPO=""
EXISTING_PROJECT=""
if [ -f "$CONFIG_FILE" ]; then
  command -v yq >/dev/null 2>&1 && {
    EXISTING_REPO=$(yq -r '.gh.repo // ""' "$CONFIG_FILE" 2>/dev/null || true)
    EXISTING_PROJECT=$(yq -r '.gh.project_id // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$EXISTING_REPO" ] && [ "$EXISTING_REPO" != "null" ] && GH_REPO="${GH_REPO:-$EXISTING_REPO}"
    [ -n "$EXISTING_PROJECT" ] && [ "$EXISTING_PROJECT" != "null" ] && GH_PROJECT_ID="${GH_PROJECT_ID:-$EXISTING_PROJECT}"
  }
fi

echo "Initialized orchestrator for $(basename "$PROJECT_DIR" .git)"
echo "  Project: $PROJECT_DIR"
[ -f "$CONFIG_FILE" ] && echo "  Config: .orchestrator.yml (existing)"

write_config() {
  if [ -z "$GH_REPO" ]; then return; fi
  export GH_REPO
  if [ -f "$CONFIG_FILE" ]; then
    yq -i ".gh.repo = strenv(GH_REPO)" "$CONFIG_FILE"
  else
    cat > "$CONFIG_FILE" <<YAML
gh:
  repo: "$GH_REPO"
  sync_label: ""
YAML
  fi
  # Ensure sync_label exists (prevents global config leak)
  existing_sync_label=$(yq -r '.gh.sync_label // "MISSING"' "$CONFIG_FILE" 2>/dev/null || echo "MISSING")
  if [ "$existing_sync_label" = "MISSING" ]; then
    yq -i '.gh.sync_label = ""' "$CONFIG_FILE"
  fi
  echo "Saved .orchestrator.yml"

  # Add orchestrator runtime files to .gitignore
  if [ -f ".gitignore" ]; then
    if ! rg -q '\.orchestrator/' .gitignore 2>/dev/null; then
      printf '\n# orchestrator runtime\n.orchestrator/\n' >> .gitignore
    fi
  else
    printf '# orchestrator runtime\n.orchestrator/\n' > .gitignore
  fi

  if [ -n "$GH_PROJECT_ID" ]; then
    export GH_PROJECT_ID
    yq -i ".gh.project_id = strenv(GH_PROJECT_ID)" "$CONFIG_FILE"
  fi

  # Auto-detect status field if gh is available and project_id is set
  local project_id="${GH_PROJECT_ID:-}"
  if [ -z "$project_id" ]; then
    project_id=$(yq -r '.gh.project_id // ""' "$CONFIG_FILE" 2>/dev/null || true)
  fi
  if [ -n "$project_id" ] && [ "$project_id" != "null" ] && command -v gh >/dev/null 2>&1; then
    auto_detect_status "$CONFIG_FILE" "$project_id"
  fi
}

configure_project_status_field() {
  local project_id="$1"
  local fields_json status_field_id
  fields_json=$(gh api graphql \
    -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name } } } } } }' \
    -f project="$project_id" 2>/dev/null || true)
  [ -n "$fields_json" ] || return 0
  status_field_id=$(printf '%s' "$fields_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null | head -n1)
  if [ -z "$status_field_id" ] || [ "$status_field_id" = "null" ]; then
    return 0
  fi
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

fetch_project_status_json() {
  local project_id="$1"
  gh api graphql \
    -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' \
    -f project="$project_id" 2>/dev/null || true
}

status_option_id_by_name() {
  local status_json="$1" option_name="$2"
  local escaped_name
  escaped_name=$(printf '%s' "$option_name" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g')
  printf '%s' "$status_json" \
    | yq -r ".data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"(?i)^${escaped_name}$\")) | .id" 2>/dev/null \
    | head -n1
}

save_resolved_status_ids() {
  local config_file="$1" status_field_id="$2" new_id="$3" inprog_id="$4" needs_review_id="$5" done_id="$6" blocked_id="${7:-}"
  export status_field_id new_id inprog_id needs_review_id done_id blocked_id

  if [ -n "$status_field_id" ] && [ "$status_field_id" != "null" ]; then
    yq -i '.gh.project_status_field_id = strenv(status_field_id)' "$config_file"
  fi

  [ -n "$new_id" ] && [ "$new_id" != "null" ] && yq -i '.gh.project_status_options.new = strenv(new_id) | .gh.project_status_options.routed = strenv(new_id)' "$config_file"
  [ -n "$inprog_id" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_options.in_progress = strenv(inprog_id)' "$config_file"
  [ -n "$needs_review_id" ] && [ "$needs_review_id" != "null" ] && yq -i '.gh.project_status_options.needs_review = strenv(needs_review_id) | .gh.project_status_options.in_review = strenv(needs_review_id)' "$config_file"
  [ -n "$done_id" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_options.done = strenv(done_id)' "$config_file"
  [ -n "$blocked_id" ] && [ "$blocked_id" != "null" ] && yq -i '.gh.project_status_options.blocked = strenv(blocked_id)' "$config_file"

  # Backward-compatible map used by older configs/commands.
  [ -n "$new_id" ] && [ "$new_id" != "null" ] && yq -i '.gh.project_status_map.backlog = strenv(new_id)' "$config_file"
  [ -n "$inprog_id" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_map.in_progress = strenv(inprog_id)' "$config_file"
  [ -n "$needs_review_id" ] && [ "$needs_review_id" != "null" ] && yq -i '.gh.project_status_map.review = strenv(needs_review_id)' "$config_file"
  [ -n "$done_id" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_map.done = strenv(done_id)' "$config_file"
}

apply_configured_status_map() {
  local config_file="$1" status_json="$2" status_field_id="$3"
  local configured_json
  configured_json=$(yq -o=json -I=0 '.gh.project.status_map // {}' "$config_file" 2>/dev/null || echo '{}')
  [ "$configured_json" != "{}" ] || return 2

  local key configured_name resolved_id
  local new_id="" inprog_id="" needs_review_id="" done_id="" blocked_id=""
  local missing=0
  local required=(new in_progress needs_review done)
  local allowed=(new in_progress needs_review done blocked)

  for key in "${required[@]}"; do
    configured_name=$(printf '%s' "$configured_json" | yq -r ".\"$key\" // \"\"")
    if [ -z "$configured_name" ] || [ "$configured_name" = "null" ]; then
      echo "Configured gh.project.status_map is missing required key: $key" >&2
      missing=1
    fi
  done

  for key in "${allowed[@]}"; do
    configured_name=$(printf '%s' "$configured_json" | yq -r ".\"$key\" // \"\"")
    [ -n "$configured_name" ] && [ "$configured_name" != "null" ] || continue
    resolved_id=$(status_option_id_by_name "$status_json" "$configured_name")
    if [ -z "$resolved_id" ] || [ "$resolved_id" = "null" ]; then
      echo "Configured gh.project.status_map.$key=\"$configured_name\" does not exist in GitHub project Status options." >&2
      missing=1
      continue
    fi
    case "$key" in
      new) new_id="$resolved_id" ;;
      in_progress) inprog_id="$resolved_id" ;;
      needs_review) needs_review_id="$resolved_id" ;;
      done) done_id="$resolved_id" ;;
      blocked) blocked_id="$resolved_id" ;;
    esac
  done

  [ "$missing" -eq 0 ] || return 1

  save_resolved_status_ids "$config_file" "$status_field_id" "$new_id" "$inprog_id" "$needs_review_id" "$done_id" "$blocked_id"
  echo "Using configured status map from .orchestrator.yml:"
  echo "  new -> $new_id"
  echo "  in_progress -> $inprog_id"
  echo "  needs_review -> $needs_review_id"
  echo "  done -> $done_id"
  [ -n "$blocked_id" ] && echo "  blocked -> $blocked_id" || echo "  blocked -> (not configured)"
  return 0
}

prompt_status_mapping() {
  local config_file="$1" status_json="$2" status_field_id="$3"
  local options_tsv
  options_tsv=$(printf '%s' "$status_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | [.id, .name] | @tsv' 2>/dev/null || true)
  [ -n "$options_tsv" ] || return 1

  local -a option_ids=()
  local -a option_names=()
  while IFS=$'\t' read -r option_id option_name; do
    [ -n "${option_id:-}" ] || continue
    option_ids+=("$option_id")
    option_names+=("$option_name")
  done <<< "$options_tsv"
  [ "${#option_ids[@]}" -gt 0 ] || return 1

  echo "Could not auto-detect status columns. Available options:"
  local i
  for ((i = 0; i < ${#option_names[@]}; i++)); do
    echo "  [$((i + 1))] ${option_names[$i]}"
  done

  pick_option_index() {
    local label="$1" default_value="$2" optional="${3:-false}" selection
    while true; do
      if [ "$optional" = "true" ]; then
        read -r -p "Map \"$label\" status to [skip]: " selection
        if [ -z "$selection" ] || [ "$selection" = "skip" ] || [ "$selection" = "s" ]; then
          echo ""
          return
        fi
      else
        read -r -p "Map \"$label\" status to [$default_value]: " selection
        selection="${selection:-$default_value}"
      fi

      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#option_ids[@]}" ]; then
        echo "$selection"
        return
      fi
      echo "Please enter a valid number between 1 and ${#option_ids[@]}." >&2
    done
  }

  local max_idx=${#option_ids[@]}
  local idx_new idx_inprog idx_review idx_done idx_blocked
  idx_new=$(pick_option_index "new" 1)
  idx_inprog=$(pick_option_index "in_progress" $(( max_idx >= 2 ? 2 : 1 )))
  idx_review=$(pick_option_index "needs_review" $(( max_idx >= 3 ? 3 : 1 )))
  idx_done=$(pick_option_index "done" $(( max_idx >= 4 ? 4 : max_idx )))
  idx_blocked=$(pick_option_index "blocked" "" true)

  local new_name inprog_name review_name done_name blocked_name=""
  local new_id inprog_id review_id done_id blocked_id=""
  new_name="${option_names[$((idx_new - 1))]}"
  inprog_name="${option_names[$((idx_inprog - 1))]}"
  review_name="${option_names[$((idx_review - 1))]}"
  done_name="${option_names[$((idx_done - 1))]}"
  new_id="${option_ids[$((idx_new - 1))]}"
  inprog_id="${option_ids[$((idx_inprog - 1))]}"
  review_id="${option_ids[$((idx_review - 1))]}"
  done_id="${option_ids[$((idx_done - 1))]}"

  if [ -n "$idx_blocked" ]; then
    blocked_name="${option_names[$((idx_blocked - 1))]}"
    blocked_id="${option_ids[$((idx_blocked - 1))]}"
  fi

  export new_name inprog_name review_name done_name blocked_name
  yq -i '.gh.project.status_map.new = strenv(new_name)' "$config_file"
  yq -i '.gh.project.status_map.in_progress = strenv(inprog_name)' "$config_file"
  yq -i '.gh.project.status_map.needs_review = strenv(review_name)' "$config_file"
  yq -i '.gh.project.status_map.done = strenv(done_name)' "$config_file"
  if [ -n "$blocked_name" ]; then
    yq -i '.gh.project.status_map.blocked = strenv(blocked_name)' "$config_file"
  fi

  save_resolved_status_ids "$config_file" "$status_field_id" "$new_id" "$inprog_id" "$review_id" "$done_id" "$blocked_id"
  echo "Saved interactive status mapping."
}

auto_detect_status() {
  local config_file="$1" project_id="$2"
  local status_json
  status_json=$(fetch_project_status_json "$project_id")
  [ -n "$status_json" ] || return 0

  local status_field_id
  status_field_id=$(printf '%s' "$status_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null | head -n1)
  if [ -z "$status_field_id" ] || [ "$status_field_id" = "null" ]; then
    return 0
  fi

  local configured_result=2
  if apply_configured_status_map "$config_file" "$status_json" "$status_field_id"; then
    return 0
  else
    configured_result=$?
  fi
  if [ "$configured_result" -eq 1 ]; then
    echo "Configured status map validation failed. Falling back to auto-detection." >&2
  fi

  find_option_id() {
    local json="$1"; shift
    for name in "$@"; do
      local opt_id
      opt_id=$(printf '%s' "$json" | yq -r ".data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"(?i)^${name}$\")) | .id" 2>/dev/null | head -n1)
      if [ -n "$opt_id" ] && [ "$opt_id" != "null" ]; then
        echo "$opt_id"
        return
      fi
    done
  }

  local new_id inprog_id review_id done_id blocked_id
  new_id=$(find_option_id "$status_json" "Backlog" "Todo" "To Do" "New" "Triage" "Planned")
  inprog_id=$(find_option_id "$status_json" "In Progress" "In progress" "Doing" "Active" "Working")
  review_id=$(find_option_id "$status_json" "Review" "In Review" "Needs Review" "QA")
  done_id=$(find_option_id "$status_json" "Done" "Completed" "Closed" "Finished")
  blocked_id=$(find_option_id "$status_json" "Blocked" "On Hold" "On-Hold" "Waiting")
  [ -n "$blocked_id" ] || blocked_id="$inprog_id"

  save_resolved_status_ids "$config_file" "$status_field_id" "$new_id" "$inprog_id" "$review_id" "$done_id" "$blocked_id"

  echo "Detected status options:"
  [ -n "$new_id" ] && echo "  new -> $new_id" || echo "  new -> (not found)"
  [ -n "$inprog_id" ] && echo "  in_progress -> $inprog_id" || echo "  in_progress -> (not found)"
  [ -n "$review_id" ] && echo "  needs_review -> $review_id" || echo "  needs_review -> (not found)"
  [ -n "$done_id" ] && echo "  done -> $done_id" || echo "  done -> (not found)"
  [ -n "$blocked_id" ] && echo "  blocked -> $blocked_id" || echo "  blocked -> (not found)"

  if [ -z "$new_id" ] || [ -z "$inprog_id" ] || [ -z "$review_id" ] || [ -z "$done_id" ]; then
    echo "Could not auto-detect all required status columns."
    if [ -t 0 ] && [ -t 1 ]; then
      prompt_status_mapping "$config_file" "$status_json" "$status_field_id" || true
    else
      echo "Configure .gh.project.status_map in .orchestrator.yml and run init again." >&2
    fi
  fi
}

# Non-interactive: explicit flags provided
if [ "$FLAG_MODE" = true ]; then
  write_config
# Interactive: terminal attached
elif [ -t 0 ]; then
  # If repo already configured, skip the "Configure?" prompt
  if [ -n "${EXISTING_REPO:-}" ] && [ "$EXISTING_REPO" != "null" ]; then
    SETUP_GH="y"
  else
    read -r -p "Configure GitHub integration? (y/N): " SETUP_GH
  fi
  if [ "$SETUP_GH" = "y" ] || [ "$SETUP_GH" = "Y" ]; then
    DETECTED_REPO=${GH_REPO:-$(cd "$PROJECT_DIR" && git remote get-url origin 2>/dev/null | sed -E 's#(https://github.com/|git@github.com:)##; s#\.git$##' || true)}
    if [ -n "$DETECTED_REPO" ]; then
      read -r -p "GitHub repo (owner/repo) [$DETECTED_REPO]: " GH_REPO_INPUT
      GH_REPO="${GH_REPO_INPUT:-$DETECTED_REPO}"
    else
      read -r -p "GitHub repo (owner/repo): " GH_REPO
    fi
    if [ -n "$GH_REPO" ]; then
      write_config

      # Configure git credential helper to use gh OAuth token (enables HTTPS push)
      if command -v gh >/dev/null 2>&1; then
        gh auth setup-git 2>/dev/null || true
      fi

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
            echo "  [n] Create new project"
            read -r -p "Select project number to use [skip]: " selection
            if [ "$selection" = "n" ] || [ "$selection" = "N" ]; then
              :  # fall through to create below
            elif [ -n "$selection" ] && [[ "$selection" =~ ^[0-9]+$ ]]; then
              idx=$((selection - 1))
              if [ $idx -ge 0 ] && [ $idx -lt ${#ids[@]} ]; then
                GH_PROJECT_ID_INPUT="${ids[$idx]}"
              fi
            fi
          fi

          # Create a new project if none selected
          if [ -z "${GH_PROJECT_ID_INPUT:-}" ]; then
            project_name=$(basename "$PROJECT_DIR" .git)
            read -r -p "Create a new GitHub Project? (y/N): " CREATE_PROJECT
            if [ "$CREATE_PROJECT" = "y" ] || [ "$CREATE_PROJECT" = "Y" ]; then
              read -r -p "Project title [$project_name]: " PROJECT_TITLE
              [ -z "$PROJECT_TITLE" ] && PROJECT_TITLE="$project_name"

              repo_owner=$(printf '%s' "$GH_REPO" | cut -d'/' -f1)
              # Determine if owner is an org or user
              owner_type=$(gh api "users/$repo_owner" -q .type 2>/dev/null || echo "User")
              if [ "$owner_type" = "Organization" ]; then
                create_json=$(gh api graphql -f query='mutation($org:ID!,$title:String!){ createProjectV2(input:{ownerId:$org, title:$title}){ projectV2{ id number } } }' \
                  -f org="$(gh api "orgs/$repo_owner" -q .node_id 2>/dev/null)" \
                  -f title="$PROJECT_TITLE" 2>/dev/null || true)
              else
                create_json=$(gh api graphql -f query='mutation($owner:ID!,$title:String!){ createProjectV2(input:{ownerId:$owner, title:$title}){ projectV2{ id number } } }' \
                  -f owner="$(gh api user -q .node_id 2>/dev/null)" \
                  -f title="$PROJECT_TITLE" 2>/dev/null || true)
              fi
              if [ -n "$create_json" ]; then
                new_id=$(printf '%s' "$create_json" | yq -r '.data.createProjectV2.projectV2.id // ""' 2>/dev/null)
                new_num=$(printf '%s' "$create_json" | yq -r '.data.createProjectV2.projectV2.number // ""' 2>/dev/null)
                if [ -n "$new_id" ] && [ "$new_id" != "null" ]; then
                  echo "Created project #$new_num: $PROJECT_TITLE"
                  configure_project_status_field "$new_id"
                  create_project_board_view "$new_num" "$repo_owner" "$owner_type"
                  link_project_to_repo "$new_id" "$GH_REPO"
                  if [ "$owner_type" = "Organization" ]; then
                    workflows_url="https://github.com/orgs/$repo_owner/projects/$new_num/workflows"
                  else
                    workflows_url="https://github.com/users/$repo_owner/projects/$new_num/workflows"
                  fi
                  echo ""
                  echo "To enable auto-add (new issues -> project), visit:"
                  echo "  $workflows_url"
                  echo "and enable 'Auto-add to project' for this repo."
                  GH_PROJECT_ID_INPUT="$new_id"
                else
                  echo "Failed to create project." >&2
                fi
              else
                echo "Failed to create project." >&2
              fi
            fi
          fi
        fi

        if [ -n "${GH_PROJECT_ID_INPUT:-}" ]; then
          GH_PROJECT_ID="$GH_PROJECT_ID_INPUT"
          export GH_PROJECT_ID
          yq -i ".gh.project_id = strenv(GH_PROJECT_ID)" "$CONFIG_FILE"
          auto_detect_status "$CONFIG_FILE" "$GH_PROJECT_ID"
        fi
      fi
    fi
  fi
fi

# Sync skills on first init
echo ""
echo "Syncing skills..."
"$SCRIPT_DIR/skills_sync.sh" 2>&1 || echo "skills sync failed (non-fatal)." >&2

echo ""
echo "Add tasks with: orchestrator add \"title\" \"body\" \"labels\""
echo "Start the server: orchestrator serve"

# Auto-sync existing GitHub issues after init
if [ -n "${GH_REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  echo ""
  echo "Syncing GitHub issues..."
  PROJECT_DIR="$PROJECT_DIR" "$SCRIPT_DIR/gh_sync.sh" || echo "gh-sync failed (non-fatal)." >&2
fi
