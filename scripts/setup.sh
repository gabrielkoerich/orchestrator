#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR=${ORCH_HOME:-"$HOME/.orchestrator"}
BIN_DIR=${BIN_DIR:-"$HOME/.bin"}

mkdir -p "$TARGET_DIR" "$BIN_DIR"

# Copy repo to target
rsync -a --delete --exclude '.git' "$(cd "$(dirname "$0")/.." && pwd)/" "$TARGET_DIR/"

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
