#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_DIR
PROJECT_NAME=$(basename "$PROJECT_DIR" .git)

init_config_file
load_project_config
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

  # Return codes:
  # 0 = merged PR found
  # 1 = no merged PR found
  # 2 = gh unavailable or API error
  if ! command -v gh >/dev/null 2>&1; then
    return 2
  fi

  pr_number=$(gh pr list \
    --repo "$repo" \
    --state merged \
    --search "closes #$issue_number" \
    --json number \
    --jq '.[0].number // ""' 2>/dev/null) || {
    # gh command failed (network, auth, rate limit, etc.)
    return 2
  }

  if [ -n "$pr_number" ]; then
    return 0
  fi

  return 1
}

log "[cleanup_worktrees] [$PROJECT_NAME] scan start"

# Query done tasks with worktrees that haven't been cleaned yet
DONE_IDS=$(db_task_ids_by_status "done")
while IFS= read -r id; do
  [ -n "$id" ] || continue

  worktree=$(db_task_field "$id" "worktree")
  branch=$(db_task_field "$id" "branch")
  project_dir=$(db_task_field "$id" "dir")
  gh_issue="$id"  # In GitHub backend, task ID = issue number
  wt_cleaned=$(db_task_field "$id" "worktree_cleaned")

  worktree=$(normalize_field "$worktree")
  branch=$(normalize_field "$branch")
  project_dir=$(normalize_field "$project_dir")

  [ -n "$worktree" ] || continue
  [ -n "$project_dir" ] || continue
  # Skip already-cleaned tasks
  [ "$wt_cleaned" = "1" ] || [ "$wt_cleaned" = "true" ] && continue

  repo=$(resolve_repo "$project_dir")
  if [ -z "$repo" ]; then
    log "[cleanup_worktrees] [$PROJECT_NAME] task=$id missing repo; skipping PR merge check"
    continue
  fi
  if ! issue_has_merged_pr "$repo" "$gh_issue"; then
    case "$?" in
      1)
        # No merged PR found for this issue — skip cleanup (expected)
        log "[cleanup_worktrees] [$PROJECT_NAME] task=$id no merged PR; skipping"
        ;;
      2)
        # gh unavailable or API error — surface an error and skip this task for now
        log_err "[cleanup_worktrees] [$PROJECT_NAME] task=$id failed to check PR status for repo=$repo issue=$gh_issue; gh unavailable or API error; skipping cleanup for now"
        ;;
      *)
        log_err "[cleanup_worktrees] [$PROJECT_NAME] task=$id issue_has_merged_pr returned unexpected code=$?; skipping"
        ;;
    esac
    continue
  fi

  cleanup_ok=true

  if [ -d "$worktree" ]; then
    log "[cleanup_worktrees] [$PROJECT_NAME] removing worktree=$worktree"
    local _git_err
    _git_err=$(git -C "$project_dir" worktree remove "$worktree" --force 2>&1) || {
      log_err "[cleanup_worktrees] [$PROJECT_NAME] failed to remove worktree=$worktree: $_git_err"
      cleanup_ok=false
    }
  fi

  if [ -n "$branch" ] && git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    log "[cleanup_worktrees] [$PROJECT_NAME] deleting branch=$branch"
    # Use -D (force) because squash-merged PRs are not considered merged by git
    local _git_err
    _git_err=$(git -C "$project_dir" branch -D "$branch" 2>&1) || {
      log_err "[cleanup_worktrees] [$PROJECT_NAME] failed to delete branch=$branch: $_git_err"
      cleanup_ok=false
    }
  fi

  if [ "$cleanup_ok" = true ]; then
    db_task_set "$id" "worktree_cleaned" "1"
    log "[cleanup_worktrees] [$PROJECT_NAME] task=$id marked worktree_cleaned=true"
  fi
done <<< "$DONE_IDS"

log "[cleanup_worktrees] [$PROJECT_NAME] scan done"
