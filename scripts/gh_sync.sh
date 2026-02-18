#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

source "$SCRIPT_DIR/lib.sh"
require_yq
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
init_config_file
load_project_config

GH_ENABLED=${GITHUB_ENABLED:-$(config_get '.gh.enabled')}
if [ -z "$GH_ENABLED" ] || [ "$GH_ENABLED" = "null" ]; then
  GH_ENABLED="true"
fi
if [ "$GH_ENABLED" != "true" ]; then
  log "[gh_sync] GitHub sync disabled."
  exit 0
fi

PROJECT_NAME=$(basename "${PROJECT_DIR:-$(pwd)}" .git)
log "[gh_sync] project=$PROJECT_NAME pull start"
"$SCRIPT_DIR/gh_pull.sh"
log "[gh_sync] project=$PROJECT_NAME pull done"
log "[gh_sync] project=$PROJECT_NAME push start"
"$SCRIPT_DIR/gh_push.sh"
log "[gh_sync] project=$PROJECT_NAME push done"
