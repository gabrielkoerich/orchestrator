#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_jobs_file

JOB_ID=${1:-}
if [ -z "$JOB_ID" ]; then
  echo "usage: jobs_remove.sh JOB_ID" >&2
  exit 1
fi

EXISTING=$(yq -r ".jobs[] | select(.id == \"$JOB_ID\") | .id" "$JOBS_PATH" 2>/dev/null || true)
if [ -z "$EXISTING" ]; then
  echo "Job '$JOB_ID' not found" >&2
  exit 1
fi

yq -i "del(.jobs[] | select(.id == \"$JOB_ID\"))" "$JOBS_PATH"
echo "Removed job '$JOB_ID'"
