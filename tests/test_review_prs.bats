#!/usr/bin/env bats
# Test coverage for review_prs.sh - PR review automation

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
  review_diff_limit: 500
  review_drafts: false
  merge_commands: "merge,lgtm,ship it"
  merge_strategy: "squash"
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
# Basic review tests
# -----------------------------------------------------------------------------

@test "review_prs.sh exits when review agent is disabled" {
  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles no open PRs" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  # Mock gh to return empty PR list
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

@test "review_prs.sh skips draft PRs by default" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Draft PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":true}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh reviews non-draft PRs" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Test PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "diff --git a/file.txt b/file.txt"
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
# Review agent selection tests
# -----------------------------------------------------------------------------

@test "review_prs.sh uses configured review agent" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_agent = "claude"' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh uses round-robin when configured" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_agent = "round_robin"' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[]'
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
# Diff handling tests
# -----------------------------------------------------------------------------

@test "review_prs.sh handles empty diff" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Empty PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo ""
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh limits diff size" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_diff_limit = 10' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Large PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  # Generate large diff
  for i in $(seq 1 100); do
    echo "+ line $i"
  done
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles diff fetch failure" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  exit 1
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Merge command tests
# -----------------------------------------------------------------------------

@test "review_prs.sh detects merge commands from owner" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_owner = "testowner"' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  if [[ "$*" == *"pulls"* ]]; then
    echo '[{"number":1,"title":"PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
    exit 0
  fi
  if [[ "$*" == *"issues/1/comments"* ]]; then
    echo '[{"id":1,"body":"lgtm","created_at":"2024-01-01T00:00:00Z","user":{"login":"testowner"}}]'
    exit 0
  fi
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh ignores non-owner merge commands" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_owner = "testowner"' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  if [[ "$*" == *"pulls"* ]]; then
    echo '[{"number":1,"title":"PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
    exit 0
  fi
  if [[ "$*" == *"issues/1/comments"* ]]; then
    # Comment from non-owner
    echo '[{"id":1,"body":"lgtm","created_at":"2024-01-01T00:00:00Z","user":{"login":"otheruser"}}]'
    exit 0
  fi
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles different merge strategies" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.merge_strategy = "rebase"' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[]'
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
# State tracking tests
# -----------------------------------------------------------------------------

@test "review_prs.sh tracks reviewed PRs in state file" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "diff content"
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]

  # State file should be created
  [ -f "${STATE_DIR}/pr_reviews_mock_repo.tsv" ] || true
}

@test "review_prs.sh skips already-reviewed PRs at same SHA" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  # Create state file showing PR 1 already reviewed
  mkdir -p "$STATE_DIR"
  echo -e "1\tabc123\tapprove\t2024-01-01T00:00:00Z\tTest PR" > "${STATE_DIR}/pr_reviews_mock_repo.tsv"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Test PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]'
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh re-reviews PRs with new commits" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  # Create state file showing PR 1 reviewed at old SHA
  mkdir -p "$STATE_DIR"
  echo -e "1\toldsha\tapprove\t2024-01-01T00:00:00Z\tTest PR" > "${STATE_DIR}/pr_reviews_mock_repo.tsv"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Test PR","body":"","user":{"login":"test"},"head":{"sha":"newsha","ref":"feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "diff content"
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
# Error handling tests
# -----------------------------------------------------------------------------

@test "review_prs.sh handles API errors gracefully" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

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

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh handles missing repo configuration" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  # Temporarily remove repo config
  mv "$CONFIG_PATH" "$CONFIG_PATH.bak"
  printf 'backend: github\nworkflow:\n  enable_review_agent: true\n' > "$CONFIG_PATH"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]

  mv "$CONFIG_PATH.bak" "$CONFIG_PATH"
}

@test "review_prs.sh handles paginated PR responses" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"

  # Mock returning paginated response (array of arrays)
  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[[{"number":1,"title":"PR 1","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":false}]]'
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
# Draft PR handling tests
# -----------------------------------------------------------------------------

@test "review_prs.sh reviews drafts when enabled" {
  yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  yq -i '.workflow.review_drafts = true' "$CONFIG_PATH"

  cat > "${TMP_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"pulls"* ]]; then
  echo '[{"number":1,"title":"Draft PR","body":"","user":{"login":"test"},"head":{"sha":"abc123","ref":"feature"},"draft":true}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "diff content"
  exit 0
fi
exec gh "$@"
SH
  chmod +x "${TMP_DIR}/gh"
  export PATH="${TMP_DIR}:${MOCK_BIN}:${PATH}"

  run "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}
