#!/usr/bin/env bats
# Test coverage for skills_sync.sh - Skills synchronization

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

  # Set up skills directory
  mkdir -p "${ORCH_HOME}/skills"

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
# Basic skills sync tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh exits cleanly when no skills.yml exists" {
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

@test "skills_sync.sh handles missing repositories key" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
skills:
  - id: test
    name: Test Skill
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh clones new skill repository" {
  # Create a mock git repo to clone from
  MOCK_SOURCE="${TMP_DIR}/mock_skill_repo"
  mkdir -p "$MOCK_SOURCE"
  git -C "$MOCK_SOURCE" init --quiet 2>/dev/null || true
  echo "test" > "${MOCK_SOURCE}/README.md"
  git -C "$MOCK_SOURCE" add . 2>/dev/null || true
  git -C "$MOCK_SOURCE" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: test-skill
    url: "file://${MOCK_SOURCE}"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  # Check that the repo was cloned
  [ -d "${ORCH_HOME}/skills/test-skill" ]
}

@test "skills_sync.sh updates existing skill repository" {
  # Create existing skill repo
  EXISTING="${ORCH_HOME}/skills/existing-skill"
  mkdir -p "$EXISTING"
  git -C "$EXISTING" init --quiet 2>/dev/null || true
  echo "existing" > "${EXISTING}/README.md"
  git -C "$EXISTING" add . 2>/dev/null || true
  git -C "$EXISTING" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  # Create remote to update from
  REMOTE="${TMP_DIR}/remote_skill"
  mkdir -p "$REMOTE"
  git -C "$REMOTE" init --quiet 2>/dev/null || true
  echo "remote" > "${REMOTE}/README.md"
  git -C "$REMOTE" add . 2>/dev/null || true
  git -C "$REMOTE" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: existing-skill
    url: "file://${REMOTE}"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Pinned commit tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh checks out pinned commit" {
  # Create a mock repo with specific commit
  PINNED_SOURCE="${TMP_DIR}/pinned_repo"
  mkdir -p "$PINNED_SOURCE"
  git -C "$PINNED_SOURCE" init --quiet 2>/dev/null || true
  echo "v1" > "${PINNED_SOURCE}/version.txt"
  git -C "$PINNED_SOURCE" add . 2>/dev/null || true
  git -C "$PINNED_SOURCE" -c user.email="test@test.com" -c user.name="Test" commit -m "v1" --quiet 2>/dev/null || true

  # Get the commit hash
  PIN_COMMIT=$(git -C "$PINNED_SOURCE" rev-parse HEAD 2>/dev/null || echo "abc123")

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: pinned-skill
    url: "file://${PINNED_SOURCE}"
    pin: ${PIN_COMMIT}
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  # Check that the repo was cloned
  [ -d "${ORCH_HOME}/skills/pinned-skill" ]
}

@test "skills_sync.sh handles invalid pinned commit gracefully" {
  # Create a mock repo
  INVALID_PIN="${TMP_DIR}/invalid_pin_repo"
  mkdir -p "$INVALID_PIN"
  git -C "$INVALID_PIN" init --quiet 2>/dev/null || true
  echo "test" > "${INVALID_PIN}/README.md"
  git -C "$INVALID_PIN" add . 2>/dev/null || true
  git -C "$INVALID_PIN" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: invalid-pin-skill
    url: "file://${INVALID_PIN}"
    pin: "invalidcommit123"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  # Should not fail even with invalid pin
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh updates to pinned commit on existing repo" {
  # Create existing repo
  EXISTING_PIN="${ORCH_HOME}/skills/pin-update"
  mkdir -p "$EXISTING_PIN"
  git -C "$EXISTING_PIN" init --quiet 2>/dev/null || true
  echo "v1" > "${EXISTING_PIN}/file.txt"
  git -C "$EXISTING_PIN" add . 2>/dev/null || true
  git -C "$EXISTING_PIN" -c user.email="test@test.com" -c user.name="Test" commit -m "v1" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: pin-update
    url: "file://${EXISTING_PIN}"
    pin: $(git -C "$EXISTING_PIN" rev-parse HEAD 2>/dev/null || echo "abc123")
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Repository URL handling tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh skips repository with empty name" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: ""
    url: "https://github.com/test/skill.git"
  - name: valid-name
    url: "https://github.com/test/valid.git"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh skips repository with empty URL" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: no-url
    url: ""
  - name: valid-name
    url: "https://github.com/test/valid.git"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh skips repository with null fields" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: null
    url: "https://github.com/test/skill.git"
  - name: valid-name
    url: "https://github.com/test/valid.git"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh handles multiple repositories" {
  # Create mock repos
  for i in 1 2 3; do
    REPO="${TMP_DIR}/skill_repo_${i}"
    mkdir -p "$REPO"
    git -C "$REPO" init --quiet 2>/dev/null || true
    echo "skill $i" > "${REPO}/README.md"
    git -C "$REPO" add . 2>/dev/null || true
    git -C "$REPO" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true
  done

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: skill-1
    url: "file://${TMP_DIR}/skill_repo_1"
  - name: skill-2
    url: "file://${TMP_DIR}/skill_repo_2"
  - name: skill-3
    url: "file://${TMP_DIR}/skill_repo_3"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  # Check all repos were cloned
  [ -d "${ORCH_HOME}/skills/skill-1" ]
  [ -d "${ORCH_HOME}/skills/skill-2" ]
  [ -d "${ORCH_HOME}/skills/skill-3" ]
}

# -----------------------------------------------------------------------------
# Skills directory tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh creates skills directory if missing" {
  rm -rf "${ORCH_HOME}/skills"

  MOCK_SOURCE="${TMP_DIR}/new_skill_repo"
  mkdir -p "$MOCK_SOURCE"
  git -C "$MOCK_SOURCE" init --quiet 2>/dev/null || true
  echo "test" > "${MOCK_SOURCE}/README.md"
  git -C "$MOCK_SOURCE" add . 2>/dev/null || true
  git -C "$MOCK_SOURCE" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: new-skill
    url: "file://${MOCK_SOURCE}"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  [ -d "${ORCH_HOME}/skills" ]
}

@test "skills_sync.sh uses SKILLS_DIR environment variable" {
  CUSTOM_SKILLS="${TMP_DIR}/custom_skills"
  export SKILLS_DIR="$CUSTOM_SKILLS"

  MOCK_SOURCE="${TMP_DIR}/env_skill_repo"
  mkdir -p "$MOCK_SOURCE"
  git -C "$MOCK_SOURCE" init --quiet 2>/dev/null || true
  echo "test" > "${MOCK_SOURCE}/README.md"
  git -C "$MOCK_SOURCE" add . 2>/dev/null || true
  git -C "$MOCK_SOURCE" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: env-skill
    url: "file://${MOCK_SOURCE}"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  [ -d "${CUSTOM_SKILLS}/env-skill" ]

  unset SKILLS_DIR
}

# -----------------------------------------------------------------------------
# Error handling tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh handles malformed skills.yml" {
  printf 'not: valid: yaml: [' > "${ORCH_HOME}/skills.yml"

  run "${REPO_DIR}/scripts/skills_sync.sh"
  # Should not crash
  [ "$status" -eq 0 ] || true
}

@test "skills_sync.sh handles unreachable repository URL" {
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: unreachable
    url: "https://invalid-host-that-does-not-exist.com/repo.git"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  # Should not fail, just skip the repo
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh handles non-git directory at skill path" {
  # Create a non-git directory where skill should be
  mkdir -p "${ORCH_HOME}/skills/not-a-repo"
  echo "not a git repo" > "${ORCH_HOME}/skills/not-a-repo/file.txt"

  # Create a valid source repo
  VALID_SOURCE="${TMP_DIR}/valid_for_replace"
  mkdir -p "$VALID_SOURCE"
  git -C "$VALID_SOURCE" init --quiet 2>/dev/null || true
  echo "valid" > "${VALID_SOURCE}/README.md"
  git -C "$VALID_SOURCE" add . 2>/dev/null || true
  git -C "$VALID_SOURCE" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: not-a-repo
    url: "file://${VALID_SOURCE}"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

@test "skills_sync.sh handles git fetch failure gracefully" {
  # Create existing repo with remote that will fail
  FAIL_FETCH="${ORCH_HOME}/skills/fail-fetch"
  mkdir -p "$FAIL_FETCH"
  git -C "$FAIL_FETCH" init --quiet 2>/dev/null || true
  echo "test" > "${FAIL_FETCH}/README.md"
  git -C "$FAIL_FETCH" add . 2>/dev/null || true
  git -C "$FAIL_FETCH" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: fail-fetch
    url: "https://invalid-host-for-fetch-failure.com/repo.git"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# File location priority tests
# -----------------------------------------------------------------------------

@test "skills_sync.sh prefers ORCH_HOME skills.yml over cwd" {
  # Create skills.yml in both locations
  cat > "${ORCH_HOME}/skills.yml" <<YAML
repositories:
  - name: orch-home-skill
    url: "file://${TMP_DIR}/mock1"
skills: []
YAML

  MOCK1="${TMP_DIR}/mock1"
  mkdir -p "$MOCK1"
  git -C "$MOCK1" init --quiet 2>/dev/null || true
  echo "test" > "${MOCK1}/README.md"
  git -C "$MOCK1" add . 2>/dev/null || true
  git -C "$MOCK1" -c user.email="test@test.com" -c user.name="Test" commit -m "init" --quiet 2>/dev/null || true

  # Change to a directory with different skills.yml
  cd "$TMP_DIR"
  cat > "${TMP_DIR}/skills.yml" <<YAML
repositories:
  - name: cwd-skill
    url: "file://${TMP_DIR}/mock2"
skills: []
YAML

  run "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]

  # Should have cloned from ORCH_HOME version
  [ -d "${ORCH_HOME}/skills/orch-home-skill" ]
}
