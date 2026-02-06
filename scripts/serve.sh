#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PID_FILE=${PID_FILE:-"${SCRIPT_DIR}/../orchestrator.pid"}
LOG_FILE=${LOG_FILE:-"${SCRIPT_DIR}/../orchestrator.log"}
INTERVAL=${INTERVAL:-10}

if [ -f "$PID_FILE" ]; then
  if kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    echo "Orchestrator already running (pid $(cat "$PID_FILE"))" >&2
    exit 1
  else
    rm -f "$PID_FILE"
  fi
fi

echo $$ > "$PID_FILE"

cleanup() {
  rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

echo "[serve] starting with interval=${INTERVAL}s" >> "$LOG_FILE"

while true; do
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[serve] tick ${ts}" >> "$LOG_FILE"
  "$SCRIPT_DIR/poll.sh" >> "$LOG_FILE" 2>&1 || true
  sleep "$INTERVAL"
done
