#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_jobs_file

SCHEDULE=${1:-}
TITLE=${2:-}
BODY=${3:-}
LABELS=${4:-}
AGENT=${5:-}

if [ -z "$SCHEDULE" ] || [ -z "$TITLE" ]; then
  echo "usage: jobs_add.sh \"SCHEDULE\" \"TITLE\" [\"BODY\"] [\"LABELS\"] [\"AGENT\"]" >&2
  echo "" >&2
  echo "  SCHEDULE: cron expression or alias (@hourly, @daily, @weekly, @monthly, @yearly)" >&2
  echo "  TITLE:    task title" >&2
  echo "  BODY:     task body (optional)" >&2
  echo "  LABELS:   comma-separated labels (optional)" >&2
  echo "  AGENT:    force agent (optional, default: router decides)" >&2
  exit 1
fi

# Validate cron expression
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if ! python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE" >/dev/null 2>&1; then
  # cron_match exits 1 for "doesn't match now" which is fine,
  # but exits 2 for invalid syntax
  RC=0
  python3 -c "
import sys; sys.path.insert(0, '${SCRIPT_DIR}')
from cron_match import ALIASES
expr = ALIASES.get('${SCHEDULE}'.strip(), '${SCHEDULE}'.strip())
fields = expr.split()
if len(fields) != 5:
    sys.exit(2)
" 2>/dev/null || RC=$?
  if [ "$RC" -eq 2 ]; then
    echo "Invalid cron expression: $SCHEDULE" >&2
    exit 1
  fi
fi

# Generate ID from title: lowercase, replace non-alnum with hyphens, trim
JOB_ID=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)

# Check for duplicate ID
EXISTING=$(yq -r ".jobs[] | select(.id == \"$JOB_ID\") | .id" "$JOBS_PATH" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "Job '$JOB_ID' already exists. Choose a different title." >&2
  exit 1
fi

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export JOB_ID SCHEDULE TITLE BODY LABELS AGENT PROJECT_DIR

yq -i \
  '.jobs += [{
    "id": strenv(JOB_ID),
    "schedule": strenv(SCHEDULE),
    "task": {
      "title": strenv(TITLE),
      "body": strenv(BODY),
      "labels": (strenv(LABELS) | split(",") | map(select(length > 0))),
      "agent": (strenv(AGENT) | select(length > 0) // null)
    },
    "dir": env(PROJECT_DIR),
    "enabled": true,
    "last_run": null,
    "last_task_status": null,
    "active_task_id": null
  }]' \
  "$JOBS_PATH"

echo "Added job '$JOB_ID' (schedule: $SCHEDULE)"
