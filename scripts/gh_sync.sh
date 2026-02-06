#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

"$SCRIPT_DIR/gh_pull.sh"
"$SCRIPT_DIR/gh_push.sh"
