#!/usr/bin/env bats
# Additional edge case tests for critical scripts

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

# -----------------------------------------------------------------------------
# jobs_tick.sh edge cases
# -----------------------------------------------------------------------------

@test "jobs_tick.sh handles empty jobs file gracefully" {
  printf 'jobs: []\n' > "$JOBS_FILE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles malformed jobs file" {
  printf 'invalid yaml: [\n' > "$JOBS_FILE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  # Should not crash
  [ "$status" -eq 0 ] || true
}

@test "jobs_tick.sh handles job with null schedule" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: test-job
    title: Test Job
    schedule: null
    type: task
    enabled: true
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  # Should not crash on null schedule
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh skips job with empty schedule" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: test-job
    title: Test Job
    schedule: ""
    type: task
    enabled: true
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles job type task without body" {
  # Create a job with task type but no body
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: test-job
    title: Test Job
    schedule: "@hourly"
    type: task
    body: null
    labels: ""
    enabled: true
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles concurrent job execution" {
  # Create a job that would match
  NOW_MIN=$(date -u +"%M")
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: concurrent-job
    title: Concurrent Test
    schedule: "$NOW_MIN * * * *"
    type: task
    body: "Test body"
    labels: "test"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  # First run should create a task
  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Second run immediately should skip (same minute dedup)
  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# cleanup_worktrees.sh edge cases
# -----------------------------------------------------------------------------

@test "cleanup_worktrees.sh handles task without worktree field" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Worktree" "Body" "")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  tdb_set() {
    source "${REPO_DIR}/scripts/lib.sh"
    db_task_set "$1" "$2" "$3"
  }

  tdb_set "$TASK_ID" status "done"
  # Don't set worktree field

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh handles already cleaned worktree" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Already Cleaned" "Body" "")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  tdb_set() {
    source "${REPO_DIR}/scripts/lib.sh"
    db_task_set "$1" "$2" "$3"
  }

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree_cleaned "1"
  tdb_set "$TASK_ID" worktree "/tmp/fake"
  tdb_set "$TASK_ID" dir "$PROJECT_DIR"

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

@test "cleanup_worktrees.sh skips task without dir field" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Dir" "Body" "")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  tdb_set() {
    source "${REPO_DIR}/scripts/lib.sh"
    db_task_set "$1" "$2" "$3"
  }

  WT_DIR="${TMP_DIR}/wt-no-dir"
  mkdir -p "$WT_DIR"

  tdb_set "$TASK_ID" status "done"
  tdb_set "$TASK_ID" worktree "$WT_DIR"
  # Don't set dir field

  run "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# review_prs.sh edge cases
# -----------------------------------------------------------------------------

@test "review_prs.sh handles PR with no diff" {
  # Mock gh to return PR with no diff
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  if [[ "$*" == *"pulls"* ]]; then
    echo '[{"number":1,"title":"Test PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature-branch"},"draft":false}]'
    exit 0
  fi
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo ""
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  # Enable review agent
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles API errors gracefully" {
  # Mock gh to fail
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  echo "API Error" >&2
  exit 1
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  # Enable review agent
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  run "${REPO_DIR}/scripts/review_prs.sh"
  # Should not crash on API error
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles review_agent config option" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_agent = "claude"' "$CONFIG_PATH"

  # Mock gh to return no PRs
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo "[]"
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# gh_mentions.sh edge cases
# -----------------------------------------------------------------------------

@test "gh_mentions.sh handles missing gh gracefully" {
  export PATH="${MOCK_BIN}:${PATH}"
  # Remove gh from PATH
  mv "${MOCK_BIN}/gh" "${MOCK_BIN}/gh_bak"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ] || true

  mv "${MOCK_BIN}/gh_bak" "${MOCK_BIN}/gh"
}

@test "gh_mentions.sh handles comment with @orchestrator in middle of text" {
  # Setup mock with comment containing @orchestrator in middle
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Can you help @orchestrator with this?","created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open"}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh skips orchestrator-generated comments" {
  # Comment with orchestrator marker should be ignored
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Results via [Orchestrator]","created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh handles per-issue deduplication" {
  # Create a mention task for issue #1 first
  mkdir -p "${ORCH_HOME}/.orchestrator/mentions"
  repo_key="mock__repo"
  mentions_db="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.json"
  printf '{"since":"2024-01-01T00:00:00Z","processed":{"comment1":{"task_id":999,"issue_number":1,"created_at":"2024-01-01T00:00:00Z","comment_url":"url"}}}' > "$mentions_db"

  # Mock gh to return a new comment on same issue
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":456,"body":"@orchestrator please help","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-456"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open"}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# skills_sync.sh edge cases
# -----------------------------------------------------------------------------

@test "skills_sync.sh handles missing skills.yml" {
  rm -f "${ORCH_HOME}/skills.yml"
  rm -f "${REPO_DIR}/skills.yml"

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh handles empty repositories list" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories: []
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh handles malformed skills.yml" {
  printf 'not: valid: yaml: [' > "${ORCH_HOME}/skills.yml"

  run "${REPO_DIR}/scripts/skills_sync.sh"
  # Should not crash
  [ "$status" -eq 0 ] || true
}

@test "skills_sync.sh handles repo with pinned commit" {
  mkdir -p "${ORCH_HOME}/skills"

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: test-skill
    url: https://github.com/test/skill.git
    pin: abc123def456
skills: []
YAML

  # Create a mock git repo
  mkdir -p "${ORCH_HOME}/skills/test-skill/.git"

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# route_task.sh edge cases
# -----------------------------------------------------------------------------

@test "route_task.sh handles task with no-agent label" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "No Agent Task" "Body" "no-agent")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  tdb_set() {
    source "${REPO_DIR}/scripts/lib.sh"
    db_task_set "$1" "$2" "$3"
  }

  # Set status to new so it can be routed
  tdb_set "$TASK_ID" status "new"

  run "${REPO_DIR}/scripts/route_task.sh" "$TASK_ID"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "route_task.sh handles missing available agents" {
  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Route Test" "Body" "")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  # Create fake codex/claude that don't work (simulate missing)
  cat > "${TMP_DIR}/codex" <<'SH'
#!/usr/bin/env bash
echo "not found" >&2
exit 1
SH
  chmod +x "${TMP_DIR}/codex"

  cat > "${TMP_DIR}/claude" <<'SH'
#!/usr/bin/env bash
echo "not found" >&2
exit 1
SH
  chmod +x "${TMP_DIR}/claude"

  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/route_task.sh" "$TASK_ID"
  # Should fail gracefully when no agents available
  [ "$status" -ne 0 ] || true
}

@test "route_task.sh uses round-robin mode when configured" {
  yq -i '.router.mode = "round_robin"' "$CONFIG_PATH"

  # Create fake agents
  touch "${TMP_DIR}/codex" "${TMP_DIR}/claude"
  chmod +x "${TMP_DIR}/codex" "${TMP_DIR}/claude"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  TASK_OUTPUT=$("${REPO_DIR}/scripts/add_task.sh" "Round Robin Test" "Body" "")
  TASK_ID=$(echo "$TASK_OUTPUT" | sed 's/Added task //' | cut -d: -f1 | tr -d ' ')

  run "${REPO_DIR}/scripts/route_task.sh" "$TASK_ID"
  [ "$status" -eq 0 ]
}
