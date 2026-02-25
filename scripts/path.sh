#!/usr/bin/env bash
# path.sh — Load user PATH for non-interactive shells.
# Sourced by tmux runner scripts so agent binaries are available even when
# launched from service environments.

if [[ -f "$HOME/.path" ]]; then
  _old_path="$PATH"
  source "$HOME/.path" >/dev/null 2>&1
  export PATH="${_old_path}:${PATH}"
fi
