#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

rm -rf "${LOCK_PATH}" "${TASKS_PATH}.lock.task."*
echo "Removed task locks."
