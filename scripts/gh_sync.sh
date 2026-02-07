#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

source "$SCRIPT_DIR/lib.sh"
require_yq
init_config_file

GH_ENABLED=${GITHUB_ENABLED:-$(config_get '.gh.enabled')}
if [ -z "$GH_ENABLED" ] || [ "$GH_ENABLED" = "null" ]; then
  GH_ENABLED="true"
fi
if [ "$GH_ENABLED" != "true" ]; then
  echo "[gh_sync] GitHub sync disabled."
  exit 0
fi

echo "[gh_sync] pull start"
"$SCRIPT_DIR/gh_pull.sh"
echo "[gh_sync] pull done"
echo "[gh_sync] push start"
"$SCRIPT_DIR/gh_push.sh"
echo "[gh_sync] push done"
