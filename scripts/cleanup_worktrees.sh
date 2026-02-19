#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
require_yq

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
PROJECT_NAME=$(basename "$PROJECT_DIR" .git)

init_config_file
load_project_config
init_tasks_file

normalize_field() {
  local value="${1:-}"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo ""
  else
    echo "$value"
  fi
}

resolve_repo() {
  local project_dir="$1"
  local repo

  repo=${GITHUB_REPO:-$(config_get '.gh.repo // ""')}
  repo=$(normalize_field "$repo")
  if [ -n "$repo" ]; then
    echo "$repo"
    return 0
  fi

  if [ -n "$project_dir" ] && [ -d "$project_dir/.git" ] && command -v gh >/dev/null 2>&1; then
    repo=$(cd "$project_dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  elif [ -n "$project_dir" ] && is_bare_repo "$project_dir"; then
    repo=$(git -C "$project_dir" config remote.origin.url 2>/dev/null \
      | sed -E 's#^https?://github\.com/##; s#^git@github\.com:##; s#\.git$##' || true)
  fi

  normalize_field "$repo"
}

issue_has_merged_pr() {
  local repo="$1"
  local issue_number="$2"
  local pr_number=""

  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi

  pr_number=$(gh pr list \
    --repo "$repo" \
    --state merged \
    --search "closes #$issue_number" \
    --json number \
    --jq '.[0].number // ""' 2>/dev/null || true)
  [ -n "$pr_number" ]
}

log "[cleanup_worktrees] [$PROJECT_NAME] scan start"

# Use @json instead of @tsv to avoid bash IFS issues with empty fields
while IFS= read -r line; do
  [ -n "$line" ] || continue

  id=$(normalize_field "$(printf '%s' "$line" | yq -r -p=json '.[0]')")
  worktree=$(normalize_field "$(printf '%s' "$line" | yq -r -p=json '.[1]')")
  branch=$(normalize_field "$(printf '%s' "$line" | yq -r -p=json '.[2]')")
  project_dir=$(normalize_field "$(printf '%s' "$line" | yq -r -p=json '.[3]')")
  gh_issue=$(normalize_field "$(printf '%s' "$line" | yq -r -p=json '.[4]')")

  [ -n "$id" ] || continue
  [ -n "$worktree" ] || continue
  [ -n "$project_dir" ] || continue

  if [ -n "$gh_issue" ]; then
    repo=$(resolve_repo "$project_dir")
    if [ -z "$repo" ]; then
      log "[cleanup_worktrees] [$PROJECT_NAME] task=$id missing repo; skipping PR merge check"
      continue
    fi
    if ! issue_has_merged_pr "$repo" "$gh_issue"; then
      continue
    fi
  fi

  cleanup_ok=true

  if [ -d "$worktree" ]; then
    log "[cleanup_worktrees] [$PROJECT_NAME] removing worktree=$worktree"
    if ! git -C "$project_dir" worktree remove "$worktree" --force >/dev/null 2>&1; then
      log_err "[cleanup_worktrees] [$PROJECT_NAME] failed to remove worktree=$worktree"
      cleanup_ok=false
    fi
  fi

  if [ -n "$branch" ] && git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    log "[cleanup_worktrees] [$PROJECT_NAME] deleting branch=$branch"
    if ! git -C "$project_dir" branch -d "$branch" >/dev/null 2>&1; then
      log_err "[cleanup_worktrees] [$PROJECT_NAME] failed to delete branch=$branch"
      cleanup_ok=false
    fi
  fi

  if [ "$cleanup_ok" = true ]; then
    NOW=$(now_iso)
    export NOW
    with_lock yq -i \
      "(.tasks[] | select(.id == $id) | .worktree_cleaned) = true |\
       (.tasks[] | select(.id == $id) | .updated_at) = strenv(NOW)" \
      "$TASKS_PATH"
    log "[cleanup_worktrees] [$PROJECT_NAME] task=$id marked worktree_cleaned=true"
  fi
done < <(task_tsv 'select(.status == "done" and (.worktree // "") != "" and .worktree_cleaned != true) | [.id, (.worktree // ""), (.branch // ""), (.dir // ""), ((.gh_issue_number // .gh_issue // "") | tostring)] | @json')

log "[cleanup_worktrees] [$PROJECT_NAME] scan done"
