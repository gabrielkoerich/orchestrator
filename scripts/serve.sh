#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PID_FILE=${PID_FILE:-"${SCRIPT_DIR}/../orchestrator.pid"}
LOG_FILE=${LOG_FILE:-"${SCRIPT_DIR}/../orchestrator.log"}
ARCHIVE_LOG=${ARCHIVE_LOG:-"${SCRIPT_DIR}/../orchestrator.archive.log"}
INTERVAL=${INTERVAL:-10}
CONFIG_PATH=${CONFIG_PATH:-"${SCRIPT_DIR}/../config.yml"}

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

# Rotate log on start
if [ -f "$LOG_FILE" ]; then
  cat "$LOG_FILE" >> "$ARCHIVE_LOG"
  : > "$LOG_FILE"
fi

lock_mtime() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo 0
    return
  fi
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
    return
  fi
  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
    return
  fi
  echo 0
}

LAST_CONFIG_MTIME=$(lock_mtime "$CONFIG_PATH")

# Sync skills on start
"$SCRIPT_DIR/skills_sync.sh" >> "$LOG_FILE" 2>&1 || true

echo "[serve] starting with interval=${INTERVAL}s" >> "$LOG_FILE"

while true; do
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[serve] tick ${ts}" >> "$LOG_FILE"
  "$SCRIPT_DIR/poll.sh" >> "$LOG_FILE" 2>&1 || true
  "$SCRIPT_DIR/gh_sync.sh" >> "$LOG_FILE" 2>&1 || true

  CURRENT_MTIME=$(lock_mtime "$CONFIG_PATH")
  if [ "$CURRENT_MTIME" -ne "$LAST_CONFIG_MTIME" ]; then
    echo "[serve] config.yml changed; restarting" >> "$LOG_FILE"
    exec "$SCRIPT_DIR/serve.sh"
  fi

  sleep "$INTERVAL"
done
