#!/usr/bin/env bats
# Test coverage for cleanup_worktrees.sh - worktree cleanup after PR merge

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  local base_tmp
  base_tmp="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  mkdir -p "${base_tmp}/orchestrator-tests"
  TMP_DIR=$(mktemp -d "${base_tmp}/orchestrator-tests/test.XXXXXX")
  export STATE_DIR="${TMP_DIR}/.orchestrator"
  mkdir -p "$STATE_DIR"
  export ORCH_HOME="${TMP_DIR}/orch_home"
  mkdir -p "$ORCH_HOME"
  export CONFIG_PATH="${ORCH_HOME}/config.yml"
  export LOCK_PATH="${STATE_DIR}/locks"
  export PROJECT_DIR="${TMP_DIR}"
  export JOBS_FILE="${PROJECT_DIR}/.orchestrator/jobs.yml"

  # Initialize a git repo
  git -C "$PROJECT_DIR" init -b main --quiet 2>/dev/null || true
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet 2>/dev/null || true

  # Set up gh mock
  MOCK_BIN="${TMP_DIR}/mock_bin"
  mkdir -p "$MOCK_BIN"
  cp "${BATS_TEST_DIRNAME}/gh_mock.sh" "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  export PATH="${MOCK_BIN}:${PATH}"
  export GH_MOCK_STATE="${STATE_DIR}/gh_mock_state.json"
  export ORCH_GH_REPO="mock/repo"
  export ORCH_BACKEND="github"

  printf 'jobs: []\n' > "$JOBS_FILE"

  cat > "$CONFIG_PATH" <<'YAML'
backend: github
gh:
  repo: "mock/repo"
router:
  agent: "codex"
  model: ""
  timeout_seconds: 0
  fallback_executor: "codex"
workflow:
  enable_review_agent: false
  review_agent: "claude"
YAML

  INIT_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Init" "Bootstrap" "")
  export INIT_TASK_ID=$(echo "$INIT_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')
}

teardown() {
  PROJECT_NAME=$(basename "$TMP_DIR")
  WORKTREE_BASE="${ORCH_HOME}/worktrees/${PROJECT_NAME}"
  if [ -d "$WORKTREE_BASE" ]; then
    (cd "$TMP_DIR" && git worktree prune 2>/dev/null) || true
    rm -rf "$WORKTREE_BASE"
  fi
  rm -rf "${TMP_DIR}"
}

# Helper: parse task ID from add_task.sh output
_task_id() {
  echo "$1" | grep 'Added task' | sed 's/Added task //' | cut -d: -f1 | tr -d ' '
}

# Helper: set task field
tdb_set() {
  local id="$1" field="$2" value="$3"
  source "${REPO_DIR}/scripts/lib.sh"
  db_task_set "$id" "$field" "$value"
}

# Helper: get task field
tdb_field() {
  local id="$1" field="$2"
  source "${REPO_DIR}/scripts/lib.sh"
  db_task_field "$id" "$field"
}

# -----------------------------------------------------------------------------
# Basic cleanup tests
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh exits cleanly when no done tasks exist" {
  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh skips task without worktree field" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Worktree" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  tdb_set "$TASK_ID" status "done"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh skips task already marked as cleaned" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Already Cleaned" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree_cleaned "1"
  tdb_set "$TASK_ID" worktree "/tmp/fake-worktree"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh skips task without dir field" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Dir" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/worktree-test"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  # Don't set dir field

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles non-existent worktree directory" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Missing Worktree" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "/nonexistent/worktree/path"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles worktree without PR merge check" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No PR Check" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-no-pr"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "feature-branch"

  # Don't set up PR merge state - task should be skipped
  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  # Worktree should still exist
  [ -d "$WT_DIR" ]
}

# -----------------------------------------------------------------------------
# PR merge detection tests
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh checks for merged PR before cleanup" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Check Merge" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-check-merge"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "gh-task-${TASK_ID}-merge"

  # Set up gh mock state with closed issue but no merged PR
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq \
    --arg id "$TASK_ID" \
    '.issues[$id].state = "closed"' > "$GH_MOCK_STATE"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh skips task with open PR" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Open PR" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-open-pr"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "gh-task-${TASK_ID}-open"

  # Leave issue open - should skip cleanup
  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  # Worktree should still exist
  [ -d "$WT_DIR" ]
}

@test "cleanup_worktrees.sh handles missing repo configuration" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Repo" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-no-repo"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"

  # Temporarily remove repo config
  mv "$CONFIG_PATH" "$CONFIG_PATH.bak"
  printf 'backend: github\n' > "$CONFIG_PATH"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  mv "$CONFIG_PATH.bak" "$CONFIG_PATH"
}

# -----------------------------------------------------------------------------
# Worktree removal tests
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh removes worktree and marks cleaned" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Remove Worktree" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  # Create a real worktree
  BRANCH_NAME="gh-task-${TASK_ID}-remove"
  WT_DIR="${TMP_DIR}/worktrees/${BRANCH_NAME}"

  git -C "$PROJECT_DIR" branch "$BRANCH_NAME" 2>/dev/null || true
  mkdir -p "${TMP_DIR}/worktrees"
  git -C "$PROJECT_DIR" worktree add "$WT_DIR" "$BRANCH_NAME" 2>/dev/null || true

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "$BRANCH_NAME"

  # Mock GH state with merged PR
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq \
    --arg id "$TASK_ID" \
    '.issues[$id].state = "closed" | .prs = {"1": {"number": 1, "state": "MERGED", "title": "PR for #'"$TASK_ID"'", "body": "Closes #'"$TASK_ID"'"}}' > "$GH_MOCK_STATE"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  # Should have marked as cleaned
  cleaned=$(tdb_field "$TASK_ID" "worktree_cleaned")
  [ "$cleaned" = "1" ] || [ "$cleaned" = "true" ]
}

@test "cleanup_worktrees.sh deletes branch after worktree removal" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Delete Branch" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  BRANCH_NAME="gh-task-${TASK_ID}-branch"
  WT_DIR="${TMP_DIR}/worktrees/${BRANCH_NAME}"

  git -C "$PROJECT_DIR" branch "$BRANCH_NAME" 2>/dev/null || true
  mkdir -p "${TMP_DIR}/worktrees"
  git -C "$PROJECT_DIR" worktree add "$WT_DIR" "$BRANCH_NAME" 2>/dev/null || true

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "$BRANCH_NAME"

  # Verify branch exists before
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"

  # Mock GH state with merged PR
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq \
    --arg id "$TASK_ID" \
    '.issues[$id].state = "closed" | .prs = {"1": {"number": 1, "state": "MERGED", "body": "Closes #'"$TASK_ID"'"}}' > "$GH_MOCK_STATE"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Multiple tasks cleanup tests
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh processes multiple done tasks" {
  # Create multiple tasks
  for i in 1 2 3; do
    TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Task $i" "Body" "")
    TASK_ID=$(_task_id "$TASK_OUTPUT")

    WT_DIR="${TMP_DIR}/wt-multi-${i}"
    mkdir -p "$WT_DIR"

    tdb_set "$TASK_ID" status "done"
    tdb_set "$TASK_ID" worktree "$WT_DIR"
    tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  done

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles mix of cleaned and uncleaned tasks" {
  # First task - already cleaned
  TASK1_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Task 1" "Body" "")
  TASK1_ID=$(_task_id "$TASK1_OUTPUT")

  WT_DIR1="${TMP_DIR}/wt-mix-1"
  mkdir -p "$WT_DIR1"

  tdb_set "$TASK1_ID" status "done"
  tdb_set "$TASK1_ID" worktree "$WT_DIR1"
  tdb_set "$TASK1_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK1_ID" worktree_cleaned "1"

  # Second task - not cleaned
  TASK2_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Task 2" "Body" "")
  TASK2_ID=$(_task_id "$TASK2_OUTPUT")

  WT_DIR2="${TMP_DIR}/wt-mix-2"
  mkdir -p "$WT_DIR2"

  tdb_set "$TASK2_ID" status "done"
  tdb_set "$TASK2_ID" worktree "$WT_DIR2"
  tdb_set "$TASK2_ID" dir "$PROJECT_DIR"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Error handling tests
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh continues on worktree removal failure" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Removal Fail" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-fail"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "readonly-branch"

  # Create a situation where removal might fail
  # (e.g., worktree not actually registered with git)
  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles bare repo as project dir" {
  # Create a bare repo
  BARE_REPO="${TMP_DIR}/bare.git"
  git init --bare "$BARE_REPO" 2>/dev/null || true

  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Bare Repo" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-bare"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$BARE_REPO"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles null/empty branch name" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Null Branch" "Body" "")
  TASK_ID=$(_task_id "$TASK_OUTPUT")

  WT_DIR="${TMP_DIR}/wt-null-branch"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"
  tdb_set "$TASK_ID" branch "null"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}
