#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STATE_DIR=${STATE_DIR:-"${ROOT_DIR}/.orchestrator"}
PID_FILE=${PID_FILE:-"${STATE_DIR}/orchestrator.pid"}
LOG_FILE=${LOG_FILE:-"${STATE_DIR}/orchestrator.log"}
ARCHIVE_LOG=${ARCHIVE_LOG:-"${STATE_DIR}/orchestrator.archive.log"}
INTERVAL=${INTERVAL:-10}
GH_PULL_INTERVAL=${GH_PULL_INTERVAL:-60}
CONFIG_PATH=${CONFIG_PATH:-"${ROOT_DIR}/config.yml"}
SERVE_LOCK=${SERVE_LOCK:-"${STATE_DIR}/serve.lock"}
TAIL_PID_FILE=${TAIL_PID_FILE:-"${STATE_DIR}/tail.pid"}
RESTARTING=${RESTARTING:-0}

mkdir -p "$STATE_DIR"

_log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"; }

# Single ownership check: PID file takes precedence over lock dir.
if [ "$RESTARTING" != "1" ]; then
  if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" >/dev/null 2>&1; then
      if [ "$EXISTING_PID" != "$$" ]; then
        echo "Orchestrator already running (pid $EXISTING_PID)."
        echo "Tip: use 'orchestrator restart' to stop and start again."
        exit 0
      fi
    else
      # Stale PID file — process is gone
      rm -f "$PID_FILE"
    fi
  fi
  # Clean stale lock dir if no live process owns it
  rm -rf "$SERVE_LOCK"
fi

if ! mkdir "$SERVE_LOCK" 2>/dev/null; then
  if [ "$RESTARTING" != "1" ]; then
    echo "Orchestrator already running (lock exists)."
    echo "Tip: use 'orchestrator restart' to stop and start again."
    exit 0
  fi
fi

if [ -d "${TASKS_PATH:-tasks.yml}.lock" ]; then
  LOCK_PATH="${TASKS_PATH:-tasks.yml}.lock"
  if command -v stat >/dev/null 2>&1; then
    if stat -f %m "$LOCK_PATH" >/dev/null 2>&1; then
      MTIME=$(stat -f %m "$LOCK_PATH")
    elif stat -c %Y "$LOCK_PATH" >/dev/null 2>&1; then
      MTIME=$(stat -c %Y "$LOCK_PATH")
    else
      MTIME=0
    fi
  else
    MTIME=0
  fi
  NOW=$(date +%s)
  STALE_SECONDS=${LOCK_STALE_SECONDS:-600}
  if [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -ge "$STALE_SECONDS" ]; then
    rm -rf "$LOCK_PATH"
  fi
fi

echo $$ > "$PID_FILE"

cleanup() {
  rm -f "$PID_FILE"
  rm -rf "$SERVE_LOCK"
  if [ -f "$TAIL_PID_FILE" ]; then
    TPID=$(cat "$TAIL_PID_FILE")
    if [ -n "$TPID" ]; then
      kill "$TPID" >/dev/null 2>&1 || true
    fi
    rm -f "$TAIL_PID_FILE"
  fi
  if [ -n "${TAIL_PID:-}" ]; then
    kill "$TAIL_PID" >/dev/null 2>&1 || true
  fi
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

clear_stale_task_lock() {
  local lock_dir="${TASKS_PATH:-tasks.yml}.lock"
  local stale_seconds=${LOCK_STALE_SECONDS:-600}
  if [ -d "$lock_dir" ]; then
    local mtime
    mtime=$(lock_mtime "$lock_dir")
    if [ "$mtime" -gt 0 ]; then
      local now
      now=$(date +%s)
      if [ $((now - mtime)) -ge "$stale_seconds" ]; then
        rm -rf "$lock_dir"
        _log "[serve] cleared stale task lock" >> "$LOG_FILE"
      fi
    fi
  fi
}

snapshot_hash() {
  # Guard: ROOT_DIR may vanish after brew upgrade deletes old cellar
  if [ ! -d "$ROOT_DIR" ]; then
    echo "stale"
    return 0
  fi
  # Hash all repo files except runtime state
  fd --type f --no-ignore --hidden \
    --exclude '.git' \
    --exclude 'tasks.yml' \
    --exclude 'jobs.yml' \
    --exclude 'config.yml' \
    --exclude '.orchestrator' \
    --exclude 'tasks.yml.lock' \
    --exclude 'tasks.yml.lock.task.*' \
    --exclude 'contexts' \
    --exclude 'skills' \
    -0 \
    . "$ROOT_DIR" \
    | xargs -0 stat -f "%m %N" 2>/dev/null \
    | sort \
    | shasum | awk '{print $1}'
}

LAST_CONFIG_MTIME=$(lock_mtime "$CONFIG_PATH")
PROJECT_CONFIG="${PROJECT_DIR:+${PROJECT_DIR}/.orchestrator.yml}"
LAST_PROJECT_CONFIG_MTIME=0
if [ -n "$PROJECT_CONFIG" ] && [ -f "$PROJECT_CONFIG" ]; then
  LAST_PROJECT_CONFIG_MTIME=$(lock_mtime "$PROJECT_CONFIG")
fi
LAST_SNAPSHOT=$(snapshot_hash)
LAST_GH_PULL=0

# Sync skills on start
"$SCRIPT_DIR/skills_sync.sh" >> "$LOG_FILE" 2>&1 || true

ORCH_VERSION="${ORCH_VERSION:-$(git describe --tags --always 2>/dev/null || echo unknown)}"
_log "[serve] starting v${ORCH_VERSION} with interval=${INTERVAL}s" >> "$LOG_FILE"

echo "Orchestrator v${ORCH_VERSION} started, listening to tasks and delegating agents." \
  "(pid $(cat "$PID_FILE"), interval ${INTERVAL}s)"

if [ "${TAIL_LOG:-0}" = "1" ]; then
  if [ -f "$TAIL_PID_FILE" ]; then
    EXISTING_TPID=$(cat "$TAIL_PID_FILE")
    if [ -n "$EXISTING_TPID" ] && kill -0 "$EXISTING_TPID" >/dev/null 2>&1; then
      :
    else
      rm -f "$TAIL_PID_FILE"
    fi
  fi
  if [ ! -f "$TAIL_PID_FILE" ]; then
    tail -n 50 -F "$LOG_FILE" &
    TAIL_PID=$!
    echo "$TAIL_PID" > "$TAIL_PID_FILE"
  fi
fi

while true; do
  _log "[serve] tick" >> "$LOG_FILE"
  clear_stale_task_lock
  "$SCRIPT_DIR/poll.sh" >> "$LOG_FILE" 2>&1 || true
  "$SCRIPT_DIR/jobs_tick.sh" >> "$LOG_FILE" 2>&1 || true
  NOW_EPOCH=$(date +%s)
  if [ $((NOW_EPOCH - LAST_GH_PULL)) -ge "$GH_PULL_INTERVAL" ]; then
    # Run gh_sync for each unique project dir
    TASKS_FILE="${TASKS_PATH:-tasks.yml}"
    if [ -f "$TASKS_FILE" ]; then
      DIRS=$(yq -r '[.tasks[].dir // ""] | unique | .[]' "$TASKS_FILE" 2>/dev/null || true)
      SYNCED_DEFAULT=false
      for dir in $DIRS; do
        if [ -n "$dir" ] && [ "$dir" != "null" ] && [ -d "$dir" ]; then
          PROJECT_DIR="$dir" "$SCRIPT_DIR/gh_sync.sh" >> "$LOG_FILE" 2>&1 || true
          SYNCED_DEFAULT=true
        fi
      done
      if [ "$SYNCED_DEFAULT" = false ]; then
        "$SCRIPT_DIR/gh_sync.sh" >> "$LOG_FILE" 2>&1 || true
      fi
    else
      "$SCRIPT_DIR/gh_sync.sh" >> "$LOG_FILE" 2>&1 || true
    fi
    LAST_GH_PULL=$NOW_EPOCH
  fi

  CURRENT_MTIME=$(lock_mtime "$CONFIG_PATH")
  if [ "$CURRENT_MTIME" -ne "$LAST_CONFIG_MTIME" ]; then
    _log "[serve] config.yml changed; restarting" >> "$LOG_FILE"
    exec env RESTARTING=1 "$SCRIPT_DIR/serve.sh"
  fi

  if [ -n "$PROJECT_CONFIG" ] && [ -f "$PROJECT_CONFIG" ]; then
    CURRENT_PROJECT_MTIME=$(lock_mtime "$PROJECT_CONFIG")
    if [ "$CURRENT_PROJECT_MTIME" -ne "$LAST_PROJECT_CONFIG_MTIME" ]; then
      _log "[serve] .orchestrator.yml changed; restarting" >> "$LOG_FILE"
      exec env RESTARTING=1 "$SCRIPT_DIR/serve.sh"
    fi
  fi

  CURRENT_SNAPSHOT=$(snapshot_hash)
  if [ "$CURRENT_SNAPSHOT" != "$LAST_SNAPSHOT" ]; then
    _log "[serve] code changed; restarting" >> "$LOG_FILE"
    exec env RESTARTING=1 "$SCRIPT_DIR/serve.sh"
  fi

  sleep "$INTERVAL"
done
