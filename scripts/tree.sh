#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq
init_tasks_file

print_tree() {
  local id=$1
  local prefix=$2
  local last=$3

  local title status agent
  title=$(yq -r ".tasks[] | select(.id == $id) | .title" "$TASKS_PATH")
  status=$(yq -r ".tasks[] | select(.id == $id) | .status" "$TASKS_PATH")
  agent=$(yq -r ".tasks[] | select(.id == $id) | .agent // \"-\"" "$TASKS_PATH")

  if [ "$last" = true ]; then
    echo "${prefix}└─ [${id}] (${status}) ${agent} - ${title}"
    prefix="${prefix}   "
  else
    echo "${prefix}├─ [${id}] (${status}) ${agent} - ${title}"
    prefix="${prefix}│  "
  fi

  local children
  children=$(yq -r ".tasks[] | select(.id == $id) | .children[]?" "$TASKS_PATH")
  if [ -n "$children" ]; then
    local count=0
    local total
    total=$(printf '%s\n' "$children" | wc -l | tr -d ' ')
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      count=$((count + 1))
      local is_last=false
      if [ "$count" -eq "$total" ]; then
        is_last=true
      fi
      print_tree "$cid" "$prefix" "$is_last"
    done <<< "$children"
  fi
}

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
FILTER=$(dir_filter)

ROOTS=$(yq -r "${FILTER} | select(.parent_id == null) | .id" "$TASKS_PATH")
if [ -z "$ROOTS" ]; then
  echo "No tasks."
  exit 0
fi

count=0
root_total=$(printf '%s\n' "$ROOTS" | wc -l | tr -d ' ')
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  count=$((count + 1))
  is_last=false
  if [ "$count" -eq "$root_total" ]; then
    is_last=true
  fi
  print_tree "$rid" "" "$is_last"
  echo
done < <(printf '%s\n' "$ROOTS")
