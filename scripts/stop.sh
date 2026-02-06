#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=${STATE_DIR:-".orchestrator"}
PID_FILE=${PID_FILE:-"${STATE_DIR}/orchestrator.pid"}

if [ ! -f "$PID_FILE" ]; then
  echo "Orchestrator not running (no pid file)."
  exit 0
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" >/dev/null 2>&1; then
  kill "$PID"
  echo "Stopped orchestrator (pid $PID)."
else
  echo "Orchestrator not running (stale pid $PID)."
fi

rm -f "$PID_FILE"
rm -rf "${STATE_DIR}/serve.lock"
if [ -f "${STATE_DIR}/tail.pid" ]; then
  TPID=$(cat "${STATE_DIR}/tail.pid")
  if [ -n "$TPID" ]; then
    kill "$TPID" >/dev/null 2>&1 || true
  fi
  rm -f "${STATE_DIR}/tail.pid"
fi
