#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_jobs_file

# Parse named args: --type bash --command "cmd" or positional for task type
JOB_TYPE="task"
COMMAND=""
SCHEDULE=""
TITLE=""
BODY=""
LABELS=""
AGENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --type)    JOB_TYPE="$2"; shift 2 ;;
    --command) COMMAND="$2"; shift 2 ;;
    *)
      # Positional args: schedule title [body] [labels] [agent]
      if [ -z "$SCHEDULE" ]; then SCHEDULE="$1"
      elif [ -z "$TITLE" ]; then TITLE="$1"
      elif [ -z "$BODY" ]; then BODY="$1"
      elif [ -z "$LABELS" ]; then LABELS="$1"
      elif [ -z "$AGENT" ]; then AGENT="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$SCHEDULE" ] || [ -z "$TITLE" ]; then
  echo "usage: jobs_add.sh \"SCHEDULE\" \"TITLE\" [\"BODY\"] [\"LABELS\"] [\"AGENT\"]" >&2
  echo "       jobs_add.sh --type bash --command \"CMD\" \"SCHEDULE\" \"TITLE\"" >&2
  echo "" >&2
  echo "  --type bash:  run a shell command directly (no LLM)" >&2
  echo "  --command:    the command to run (required for type=bash)" >&2
  echo "  SCHEDULE:     cron expression or alias (@hourly, @daily, @weekly, @monthly, @yearly)" >&2
  echo "  TITLE:        job title" >&2
  echo "  BODY:         task body (optional, ignored for type=bash)" >&2
  echo "  LABELS:       comma-separated labels (optional)" >&2
  echo "  AGENT:        force agent (optional, default: router decides)" >&2
  exit 1
fi

if [ "$JOB_TYPE" = "bash" ] && [ -z "$COMMAND" ]; then
  echo "error: --command is required for --type bash" >&2
  exit 1
fi

# Validate cron expression
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if ! python3 "${SCRIPT_DIR}/cron_match.py" "$SCHEDULE" >/dev/null 2>&1; then
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

# Generate ID from title
JOB_ID=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)

# Check for duplicate ID
EXISTING=$(yq -r ".jobs[] | select(.id == \"$JOB_ID\") | .id" "$JOBS_PATH" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "Job '$JOB_ID' already exists. Choose a different title." >&2
  exit 1
fi

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export JOB_ID SCHEDULE TITLE BODY LABELS AGENT PROJECT_DIR JOB_TYPE COMMAND

yq -i \
  '.jobs += [{
    "id": strenv(JOB_ID),
    "type": strenv(JOB_TYPE),
    "schedule": strenv(SCHEDULE),
    "task": {
      "title": strenv(TITLE),
      "body": strenv(BODY),
      "labels": (strenv(LABELS) | split(",") | map(select(length > 0))),
      "agent": (strenv(AGENT) | select(length > 0) // null)
    },
    "command": (strenv(COMMAND) | select(length > 0) // null),
    "dir": strenv(PROJECT_DIR),
    "enabled": true,
    "last_run": null,
    "last_task_status": null,
    "active_task_id": null
  }]' \
  "$JOBS_PATH"

if [ "$JOB_TYPE" = "bash" ]; then
  echo "Added bash job '$JOB_ID' (schedule: $SCHEDULE, command: $COMMAND)"
else
  echo "Added job '$JOB_ID' (schedule: $SCHEDULE)"
fi
