#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "[gh_sync] pull start"
"$SCRIPT_DIR/gh_pull.sh"
echo "[gh_sync] pull done"
echo "[gh_sync] push start"
"$SCRIPT_DIR/gh_push.sh"
echo "[gh_sync] push done"
