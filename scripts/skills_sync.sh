#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

SKILLS_DIR=${SKILLS_DIR:-"skills"}
mkdir -p "$SKILLS_DIR"

REPO_COUNT=$(yq -r '.repositories | length' skills.yml)
if [ "$REPO_COUNT" -eq 0 ]; then
  echo "No repositories in skills.yml" >&2
  exit 0
fi

for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(yq -r ".repositories[$i].name" skills.yml)
  URL=$(yq -r ".repositories[$i].url" skills.yml)
  PIN=$(yq -r ".repositories[$i].pin // \"\"" skills.yml)
  if [ -z "$NAME" ] || [ -z "$URL" ] || [ "$NAME" = "null" ] || [ "$URL" = "null" ]; then
    continue
  fi

  DEST="$SKILLS_DIR/$NAME"
  if [ -d "$DEST/.git" ]; then
    echo "Updating $NAME"
    git -C "$DEST" fetch --all --prune >/dev/null 2>&1 || true
    if [ -n "$PIN" ] && [ "$PIN" != "null" ]; then
      git -C "$DEST" checkout "$PIN" --quiet 2>/dev/null || true
      echo "  pinned to $PIN"
    else
      git -C "$DEST" pull --ff-only >/dev/null 2>&1 || true
    fi
  else
    echo "Cloning $NAME"
    git clone "$URL" "$DEST" >/dev/null 2>&1 || true
    if [ -n "$PIN" ] && [ "$PIN" != "null" ]; then
      git -C "$DEST" checkout "$PIN" --quiet 2>/dev/null || true
      echo "  pinned to $PIN"
    fi
  fi

done
