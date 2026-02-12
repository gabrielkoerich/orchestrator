#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR=${ORCH_HOME:-"$HOME/.orchestrator"}
BIN_DIR=${BIN_DIR:-"$HOME/.bin"}

mkdir -p "$TARGET_DIR" "$BIN_DIR"

# Copy repo to target, preserving local state/config
rsync -a --delete \
  --exclude '.git' \
  --exclude 'tasks.yml' \
  --exclude 'jobs.yml' \
  --exclude 'config.yml' \
  --exclude 'contexts/' \
  --exclude 'skills/' \
  "$(cd "$(dirname "$0")/.." && pwd)/" "$TARGET_DIR/"

# Initialize config if missing
if [ ! -f "$TARGET_DIR/config.yml" ] && [ -f "$TARGET_DIR/config.example.yml" ]; then
  cp "$TARGET_DIR/config.example.yml" "$TARGET_DIR/config.yml"
fi

# Optional interactive config
if [ -t 0 ]; then
  read -r -p "Enable GitHub sync now? (y/N): " ENABLE_GH
  if [ "${ENABLE_GH}" = "y" ] || [ "${ENABLE_GH}" = "Y" ]; then
    echo "Make sure you are logged in: gh auth login"
    read -r -p "GitHub repo (owner/repo) [skip]: " GH_REPO_INPUT
    read -r -p "GitHub Project ID [auto-detect if blank]: " GH_PROJECT_ID_INPUT

    if [ -n "$GH_REPO_INPUT" ]; then
      export GH_REPO_INPUT
      yq -i ".gh.repo = env(GH_REPO_INPUT)" "$TARGET_DIR/config.yml"
    fi

    if [ -z "$GH_PROJECT_ID_INPUT" ]; then
      # Try auto-detect if user left it blank
      if command -v gh >/dev/null 2>&1; then
        user_login=$(gh api user -q .login 2>/dev/null || true)
        user_node_id=$(gh api user -q .node_id 2>/dev/null || true)
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
        else
          read -r -p "No projects found. Create one? (y/N): " CREATE_PROJ
          if [ "${CREATE_PROJ}" = "y" ] || [ "${CREATE_PROJ}" = "Y" ]; then
            owner_label="user:${user_login}"
            owner_id="$user_node_id"

            if [ -n "$orgs" ]; then
              echo "Choose owner:"
              echo "  [1] $owner_label"
              idx=2
              while IFS= read -r org; do
                [ -n "$org" ] || continue
                echo "  [$idx] org:${org}"
                idx=$((idx + 1))
              done <<< "$orgs"
              read -r -p "Owner number [1]: " owner_sel
              owner_sel=${owner_sel:-1}
              if [[ "$owner_sel" =~ ^[0-9]+$ ]] && [ "$owner_sel" -gt 1 ]; then
                sel_idx=2
                while IFS= read -r org; do
                  [ -n "$org" ] || continue
                  if [ "$sel_idx" -eq "$owner_sel" ]; then
                    owner_label="org:${org}"
                    owner_id=$(gh api "orgs/$org" -q .node_id 2>/dev/null || true)
                    break
                  fi
                  sel_idx=$((sel_idx + 1))
                done <<< "$orgs"
              fi
            fi

            read -r -p "Project title [Orchestrator]: " proj_title
            proj_title=${proj_title:-Orchestrator}

            if [ -n "$owner_id" ]; then
              create_json=$(gh api graphql -f query='mutation($owner:ID!, $title:String!){ createProjectV2(input:{ownerId:$owner, title:$title}){ projectV2{ id title } } }' -f owner="$owner_id" -f title="$proj_title" 2>/dev/null || true)
              GH_PROJECT_ID_INPUT=$(printf '%s' "$create_json" | yq -r '.data.createProjectV2.projectV2.id' 2>/dev/null || true)
              if [ -n "$GH_PROJECT_ID_INPUT" ] && [ "$GH_PROJECT_ID_INPUT" != "null" ]; then
                echo "Created project: $proj_title ($GH_PROJECT_ID_INPUT)"
                # Create Status single-select field with defaults
                field_json=$(gh api graphql -f query='mutation($project:ID!){ createProjectV2Field(input:{projectId:$project, name:"Status", dataType:SINGLE_SELECT, singleSelectOptions:[{name:"Backlog"},{name:"In Progress"},{name:"Review"},{name:"Done"}]}){ projectV2Field{ ... on ProjectV2SingleSelectField { id name options { id name } } } } }' -f project="$GH_PROJECT_ID_INPUT" 2>/dev/null || true)
                status_field_id=$(printf '%s' "$field_json" | yq -r '.data.createProjectV2Field.projectV2Field.id' 2>/dev/null || true)
                backlog_id=$(printf '%s' "$field_json" | yq -r '.data.createProjectV2Field.projectV2Field.options[] | select(.name == "Backlog") | .id' 2>/dev/null || true)
                inprog_id=$(printf '%s' "$field_json" | yq -r '.data.createProjectV2Field.projectV2Field.options[] | select(.name == "In Progress") | .id' 2>/dev/null || true)
                review_id=$(printf '%s' "$field_json" | yq -r '.data.createProjectV2Field.projectV2Field.options[] | select(.name == "Review") | .id' 2>/dev/null || true)
                done_id=$(printf '%s' "$field_json" | yq -r '.data.createProjectV2Field.projectV2Field.options[] | select(.name == "Done") | .id' 2>/dev/null || true)
                export status_field_id backlog_id inprog_id review_id done_id
                if [ -n "$status_field_id" ] && [ "$status_field_id" != "null" ]; then
                  yq -i ".gh.project_status_field_id = env(status_field_id)" "$TARGET_DIR/config.yml"
                fi
                [ -n "$backlog_id" ] && [ "$backlog_id" != "null" ] && yq -i '.gh.project_status_map.backlog = env(backlog_id)' "$TARGET_DIR/config.yml"
                [ -n "$inprog_id" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_map.in_progress = env(inprog_id)' "$TARGET_DIR/config.yml"
                [ -n "$review_id" ] && [ "$review_id" != "null" ] && yq -i '.gh.project_status_map.review = env(review_id)' "$TARGET_DIR/config.yml"
                [ -n "$done_id" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_map.done = env(done_id)' "$TARGET_DIR/config.yml"
              fi
            fi
          fi
        fi
      fi
    fi

    if [ -n "$GH_PROJECT_ID_INPUT" ]; then
      export GH_PROJECT_ID_INPUT
      yq -i ".gh.project_id = env(GH_PROJECT_ID_INPUT)" "$TARGET_DIR/config.yml"

      echo
      # Auto-fetch Status field + option IDs if present
      status_json=$(gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }' -f project="$GH_PROJECT_ID_INPUT" 2>/dev/null || true)
      if [ -n "$status_json" ]; then
        status_field_id=$(printf '%s' "$status_json" | yq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null | head -n1)

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

        backlog_id=$(find_option_id "$status_json" "Backlog" "Todo" "To Do" "New")
        inprog_id=$(find_option_id "$status_json" "In Progress" "In progress" "Doing" "Active" "Working")
        review_id=$(find_option_id "$status_json" "Review" "In Review" "Needs Review")
        done_id=$(find_option_id "$status_json" "Done" "Completed" "Closed" "Finished")

        export status_field_id backlog_id inprog_id review_id done_id
        if [ -n "$status_field_id" ] && [ "$status_field_id" != "null" ]; then
          yq -i ".gh.project_status_field_id = env(status_field_id)" "$TARGET_DIR/config.yml"
        fi
        [ -n "$backlog_id" ] && [ "$backlog_id" != "null" ] && yq -i '.gh.project_status_map.backlog = env(backlog_id)' "$TARGET_DIR/config.yml"
        [ -n "$inprog_id" ] && [ "$inprog_id" != "null" ] && yq -i '.gh.project_status_map.in_progress = env(inprog_id)' "$TARGET_DIR/config.yml"
        [ -n "$review_id" ] && [ "$review_id" != "null" ] && yq -i '.gh.project_status_map.review = env(review_id)' "$TARGET_DIR/config.yml"
        [ -n "$done_id" ] && [ "$done_id" != "null" ] && yq -i '.gh.project_status_map.done = env(done_id)' "$TARGET_DIR/config.yml"

        # Show what was detected
        echo "Detected status options:"
        [ -n "$backlog_id" ] && echo "  backlog -> $backlog_id" || echo "  backlog -> (not found)"
        [ -n "$inprog_id" ] && echo "  in_progress -> $inprog_id" || echo "  in_progress -> (not found)"
        [ -n "$review_id" ] && echo "  review -> $review_id" || echo "  review -> (not found)"
        [ -n "$done_id" ] && echo "  done -> $done_id" || echo "  done -> (not found)"
      fi

      # If still missing, offer manual input
      if [ -z "$status_field_id" ] || [ "$status_field_id" = "null" ]; then
        echo "Tip: run 'just gh-project-info' to list Status field and option IDs."
        read -r -p "Configure Project status option IDs now? (y/N): " CONFIGURE_STATUS
        if [ "${CONFIGURE_STATUS}" = "y" ] || [ "${CONFIGURE_STATUS}" = "Y" ]; then
          read -r -p "Status field ID [skip]: " STATUS_FIELD_ID
          read -r -p "Backlog option ID [skip]: " OPT_BACKLOG
          read -r -p "In Progress option ID [skip]: " OPT_INPROG
          read -r -p "Review option ID [skip]: " OPT_REVIEW
          read -r -p "Done option ID [skip]: " OPT_DONE

          if [ -n "$STATUS_FIELD_ID" ]; then
            export STATUS_FIELD_ID
            yq -i ".gh.project_status_field_id = env(STATUS_FIELD_ID)" "$TARGET_DIR/config.yml"
          fi

          if [ -n "$OPT_BACKLOG" ]; then export OPT_BACKLOG; yq -i '.gh.project_status_map.backlog = env(OPT_BACKLOG)' "$TARGET_DIR/config.yml"; fi
          if [ -n "$OPT_INPROG" ]; then export OPT_INPROG; yq -i '.gh.project_status_map.in_progress = env(OPT_INPROG)' "$TARGET_DIR/config.yml"; fi
          if [ -n "$OPT_REVIEW" ]; then export OPT_REVIEW; yq -i '.gh.project_status_map.review = env(OPT_REVIEW)' "$TARGET_DIR/config.yml"; fi
          if [ -n "$OPT_DONE" ]; then export OPT_DONE; yq -i '.gh.project_status_map.done = env(OPT_DONE)' "$TARGET_DIR/config.yml"; fi
        fi
      fi
    fi
  fi
fi

# Sync skills catalog
"$TARGET_DIR/scripts/skills_sync.sh" || true

# Install justfile shortcut
cat > "$BIN_DIR/orchestrator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
cd "$HOME/.orchestrator"
just "$@"
EOF
chmod +x "$BIN_DIR/orchestrator"

if [ -f "$TARGET_DIR/config.yml" ]; then
  gh_project_id=$(yq -r '.gh.project_id // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)
  gh_status_field_id=$(yq -r '.gh.project_status_field_id // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)
  gh_backlog_id=$(yq -r '.gh.project_status_map.backlog // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)
  gh_inprog_id=$(yq -r '.gh.project_status_map.in_progress // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)
  gh_review_id=$(yq -r '.gh.project_status_map.review // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)
  gh_done_id=$(yq -r '.gh.project_status_map.done // ""' "$TARGET_DIR/config.yml" 2>/dev/null || true)

  echo
  echo "GitHub Project config set:"
  if [ -n "$gh_project_id" ] && [ "$gh_project_id" != "null" ]; then
    echo "  project_id: $gh_project_id"
  else
    echo "  project_id: (not set)"
  fi
  if [ -n "$gh_status_field_id" ] && [ "$gh_status_field_id" != "null" ]; then
    echo "  status_field_id: $gh_status_field_id"
  else
    echo "  status_field_id: (not set)"
  fi
  echo "  status_map (set):"
  status_map_set=false
  if [ -n "$gh_backlog_id" ] && [ "$gh_backlog_id" != "null" ]; then
    echo "    backlog: $gh_backlog_id"
    status_map_set=true
  fi
  if [ -n "$gh_inprog_id" ] && [ "$gh_inprog_id" != "null" ]; then
    echo "    in_progress: $gh_inprog_id"
    status_map_set=true
  fi
  if [ -n "$gh_review_id" ] && [ "$gh_review_id" != "null" ]; then
    echo "    review: $gh_review_id"
    status_map_set=true
  fi
  if [ -n "$gh_done_id" ] && [ "$gh_done_id" != "null" ]; then
    echo "    done: $gh_done_id"
    status_map_set=true
  fi
  if [ "$status_map_set" = false ]; then
    echo "    (none)"
  fi
fi

# Check available agents
echo
echo "Agent CLIs:"
has_agent=false
for agent in claude codex opencode; do
  if command -v "$agent" >/dev/null 2>&1; then
    echo "  $agent: $(command -v "$agent")"
    has_agent=true
  else
    echo "  $agent: not found"
  fi
done
if [ "$has_agent" = false ]; then
  echo
  echo "Error: No agent CLIs found. Install at least one (claude, codex, or opencode)." >&2
  exit 1
fi

echo
echo "Installed to $TARGET_DIR"
echo "Binary: $BIN_DIR/orchestrator"

# Offer launchd service on macOS
if [ "$(uname)" = "Darwin" ] && [ -t 0 ]; then
  echo
  read -r -p "Install macOS background service (auto-start + restart on crash)? (y/N): " INSTALL_SERVICE
  if [ "${INSTALL_SERVICE}" = "y" ] || [ "${INSTALL_SERVICE}" = "Y" ]; then
    "$TARGET_DIR/scripts/service_install.sh"
  fi
fi
