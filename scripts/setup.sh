#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR=${ORCH_HOME:-"$HOME/.orchestrator"}
BIN_DIR=${BIN_DIR:-"$HOME/.bin"}

mkdir -p "$TARGET_DIR" "$BIN_DIR"

# Copy repo to target
rsync -a --delete --exclude '.git' "$(cd "$(dirname "$0")/.." && pwd)/" "$TARGET_DIR/"

# Initialize config if missing
if [ ! -f "$TARGET_DIR/config.yml" ] && [ -f "$TARGET_DIR/config.example.yml" ]; then
  cp "$TARGET_DIR/config.example.yml" "$TARGET_DIR/config.yml"
fi

# Optional interactive config
if [ -t 0 ]; then
  read -r -p "Enable GitHub sync now? (y/N): " ENABLE_GH
  if [ "${ENABLE_GH}" = "y" ] || [ "${ENABLE_GH}" = "Y" ]; then
    read -r -p "GitHub token (GITHUB_TOKEN) [skip]: " GH_TOKEN_INPUT
    read -r -p "GitHub repo (owner/repo) [skip]: " GH_REPO_INPUT
    read -r -p "GitHub Project ID [skip]: " GH_PROJECT_ID_INPUT

    if [ -n "$GH_TOKEN_INPUT" ]; then
      echo "GITHUB_TOKEN=$GH_TOKEN_INPUT" > "$TARGET_DIR/.env"
    fi

    if [ -n "$GH_REPO_INPUT" ]; then
      export GH_REPO_INPUT
      yq -i ".gh.repo = env(GH_REPO_INPUT)" "$TARGET_DIR/config.yml"
    fi

    if [ -n "$GH_PROJECT_ID_INPUT" ]; then
      export GH_PROJECT_ID_INPUT
      yq -i ".gh.project_id = env(GH_PROJECT_ID_INPUT)" "$TARGET_DIR/config.yml"

      echo "Configure GitHub Project columns (press Enter to keep defaults)"
      read -r -p "Backlog column name [Backlog]: " COL_BACKLOG
      read -r -p "In Progress column name [In Progress]: " COL_INPROG
      read -r -p "Review column name [Review]: " COL_REVIEW
      read -r -p "Done column name [Done]: " COL_DONE

      COL_BACKLOG=${COL_BACKLOG:-Backlog}
      COL_INPROG=${COL_INPROG:-In Progress}
      COL_REVIEW=${COL_REVIEW:-Review}
      COL_DONE=${COL_DONE:-Done}

      export COL_BACKLOG COL_INPROG COL_REVIEW COL_DONE
      yq -i \
        '.gh.project_status_map |= {backlog: env(COL_BACKLOG), in_progress: env(COL_INPROG), review: env(COL_REVIEW), done: env(COL_DONE)}' \
        "$TARGET_DIR/config.yml"
    fi
  fi
fi

# Install justfile shortcut
cat > "$BIN_DIR/orchestrator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/.orchestrator"
just "$@"
EOF
chmod +x "$BIN_DIR/orchestrator"

echo "Installed to $TARGET_DIR"
echo "Binary: $BIN_DIR/orchestrator"
