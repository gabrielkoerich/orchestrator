#!/usr/bin/env bash
set -euo pipefail

if ! crontab -l 2>/dev/null | grep -qF "orchestrator jobs-tick"; then
  echo "No crontab entry found for orchestrator jobs-tick"
  exit 0
fi

(crontab -l 2>/dev/null | grep -vF "orchestrator jobs-tick") | crontab -

echo "Removed crontab entry for orchestrator jobs-tick"
