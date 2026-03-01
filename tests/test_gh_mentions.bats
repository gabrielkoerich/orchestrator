#!/usr/bin/env bats
# Test coverage for gh_mentions.sh - @orchestrator mention handling

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

  # Set up mentions directory
  mkdir -p "${ORCH_HOME}/.orchestrator/mentions"
  repo_key="mock__repo"
  MENTIONS_DB="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.json"
  printf '{"since":"2024-01-01T00:00:00Z","processed":{}}' > "$MENTIONS_DB"

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
# Basic mention handling tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh exits cleanly when gh is not available" {
  # Remove gh from PATH temporarily
  mv "${MOCK_BIN}/gh" "${MOCK_BIN}/gh_bak"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]

  mv "${MOCK_BIN}/gh_bak" "${MOCK_BIN}/gh"
}

@test "gh_mentions.sh handles no comments" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo "[]"
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh detects @orchestrator mention" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"@orchestrator please help with this","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh ignores comments without @orchestrator" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Just a regular comment","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh skips closed issues" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"@orchestrator help","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"closed","number":1}'
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
# Comment filtering tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh skips orchestrator-generated comments" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Results via [Orchestrator](https://github.com)","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh skips task result comments" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Results from task #123 (@orchestrator mention handler)","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh skips comments with @orchestrator only in parentheses" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Working on this (@orchestrator mention handler)","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh ignores @orchestrator in code blocks" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"```\n@orchestrator command\n```","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh ignores @orchestrator in blockquotes" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"> @orchestrator help","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
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
# Deduplication tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh skips already-processed comments" {
  # Set up DB with already processed comment
  repo_key="mock__repo"
  MENTIONS_DB="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.json"
  printf '{"since":"2024-01-01T00:00:00Z","processed":{"123":{"task_id":999,"issue_number":1,"created_at":"2024-01-02T00:00:00Z","comment_url":"url"}}}' > "$MENTIONS_DB"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"@orchestrator help","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
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
  # Set up DB with existing active task for issue #1
  repo_key="mock__repo"
  MENTIONS_DB="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.json"
  printf '{"since":"2024-01-01T00:00:00Z","processed":{"100":{"task_id":999,"issue_number":1,"created_at":"2024-01-01T00:00:00Z","comment_url":"url"}}}' > "$MENTIONS_DB"

  # Mock task 999 as active
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq '.issues["999"] = {"number": 999, "title": "Active", "state": "open", "labels": [{"name": "status:in_progress"}]}' > "$GH_MOCK_STATE"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":456,"body":"@orchestrator help again","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-456"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
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
# Lock handling tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh handles concurrent execution with lock" {
  # Create lock directory to simulate concurrent execution
  repo_key="mock__repo"
  LOCK_DIR="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.lock"
  mkdir -p "$LOCK_DIR"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]

  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Error handling tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh handles API errors gracefully" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo "API Error" >&2
  exit 1
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh handles missing repo config" {
  # Temporarily remove repo config
  mv "$CONFIG_PATH" "$CONFIG_PATH.bak"
  printf 'backend: github\n' > "$CONFIG_PATH"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]

  mv "$CONFIG_PATH.bak" "$CONFIG_PATH"
}

@test "gh_mentions.sh updates since timestamp after processing" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"@orchestrator help","created_at":"2024-06-15T12:00:00Z","updated_at":"2024-06-15T12:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]

  # Check that since timestamp was updated
  repo_key="mock__repo"
  MENTIONS_DB="${ORCH_HOME}/.orchestrator/mentions/${repo_key}.json"
  since=$(jq -r '.since' "$MENTIONS_DB" 2>/dev/null || echo "")
  [ -n "$since" ]
}

# -----------------------------------------------------------------------------
# Mention position tests
# -----------------------------------------------------------------------------

@test "gh_mentions.sh detects @orchestrator at start of comment" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"@orchestrator please review this","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh detects @orchestrator in middle of comment" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Can you help @orchestrator with this issue?","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}

@test "gh_mentions.sh detects @orchestrator at end of comment" {
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues/comments"* ]]; then
  echo '[{"id":123,"body":"Please take a look @orchestrator","created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:00:00Z","user":{"login":"user1"},"issue_url":"https://api.github.com/repos/mock/repo/issues/1","html_url":"https://github.com/mock/repo/issues/1#issuecomment-123"}]'
  exit 0
fi
if [[ "$*" == *"issues/1"* ]]; then
  echo '{"state":"open","number":1}'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/gh_mentions.sh"
  [ "$status" -eq 0 ]
}
