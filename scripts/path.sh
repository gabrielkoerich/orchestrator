#!/usr/bin/env bash
# path.sh — Load user PATH and shell functions for non-interactive shells
# Sourced by tmux runner scripts so agents have access to tools defined
# in ~/.path and shell functions (e.g. kimi, minimax) from ~/.functions.

if [[ -f "$HOME/.path" ]]; then
  _old_path="$PATH"
  source "$HOME/.path" >/dev/null 2>&1
  export PATH="${_old_path}:${PATH}"
fi

[[ -f "$HOME/.functions" ]] && source "$HOME/.functions" >/dev/null 2>&1 || true
