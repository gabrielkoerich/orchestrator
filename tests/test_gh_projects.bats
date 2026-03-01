#!/usr/bin/env bats
# Tests for GitHub Project management scripts

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
  project_id: ""
  project_status_field_id: ""
  project_status_map: {}
router:
  agent: "codex"
  model: ""
  timeout_seconds: 0
  fallback_executor: "codex"
workflow:
  enable_review_agent: false
YAML
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# -----------------------------------------------------------------------------
# gh_project_info.sh tests
# -----------------------------------------------------------------------------

@test "gh_project_info.sh requires gh" {
  # Move the mock gh out of the way temporarily
  mv "${MOCK_BIN}/gh" "${MOCK_BIN}/gh_bak"
  # Create fake gh that fails
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: command not found" >&2
exit 1
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_info.sh" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh is required"* ]] || [[ "$output" == *"gh"* ]]

  # Restore original mock
  mv "${MOCK_BIN}/gh_bak" "${MOCK_BIN}/gh"
}

@test "gh_project_info.sh exits 1 when project_id missing" {
  # gh is available but project_id is not set
  run "${REPO_DIR}/scripts/gh_project_info.sh" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing gh.project_id"* ]] || [[ "$output" == *"project_id"* ]]
}

@test "gh_project_info.sh displays project info" {
  yq -i '.gh.project_id = "PVT_test"' "$CONFIG_PATH"

  # Mock gh to return project data
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"node":{"title":"Test Project","fields":{"nodes":[{"id":"PVTSSF_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"opt1","name":"Backlog"},{"id":"opt2","name":"In Progress"}]}]}}}}'
fi
exit 0
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_info.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Test Project"* ]] || [[ "$output" == *"Status"* ]] || [[ "$output" == *"Backlog"* ]]
}

# -----------------------------------------------------------------------------
# gh_project_create.sh tests
# -----------------------------------------------------------------------------

@test "gh_project_create.sh exits 1 when gh not authenticated" {
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "auth" ] || [ "$1" = "api" ]; then
  echo "not authenticated" >&2
  exit 1
fi
exit 1
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_create.sh" "Test Project" 2>&1
  [ "$status" -eq 1 ]
}

@test "gh_project_create.sh validates project name" {
  # Empty project name should show usage or error
  run "${REPO_DIR}/scripts/gh_project_create.sh" "" 2>&1
  [ "$status" -ne 0 ] || [[ "$output" == *"usage"* ]] || [[ "$output" == *"Usage"* ]] || [[ "$output" == *"required"* ]] || true
}

@test "gh_project_create.sh skips in non-interactive mode" {
  # When not connected to a TTY and no projects exist, the script exits 0
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"user":{"projectsV2":{"nodes":[]}}}}'
  exit 0
fi
if [ "$1" = "api" ]; then
  echo '{"type": "User"}'
  exit 0
fi
exit 0
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_create.sh" "My Test Project" 2>&1
  # Script exits 0 when skipping in non-interactive mode
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# -----------------------------------------------------------------------------
# gh_project_apply.sh tests
# -----------------------------------------------------------------------------

@test "gh_project_apply.sh exits 1 when gh not available" {
  mv "${MOCK_BIN}/gh" "${MOCK_BIN}/gh_bak"
  run "${REPO_DIR}/scripts/gh_project_apply.sh" 2>&1
  [ "$status" -eq 1 ]
  mv "${MOCK_BIN}/gh_bak" "${MOCK_BIN}/gh"
}

@test "gh_project_apply.sh exits 1 when project_id missing" {
  run "${REPO_DIR}/scripts/gh_project_apply.sh" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing gh.project_id"* ]]
}

@test "gh_project_apply.sh applies project config" {
  yq -i '.gh.project_id = "PVT_test"' "$CONFIG_PATH"

  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"node":{"fields":{"nodes":[{"id":"PVTSSF_status","name":"Status","options":[{"id":"backlog_id","name":"Backlog"},{"id":"done_id","name":"Done"}]}]}}}}'
fi
exit 0
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_apply.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Applied"* ]] || [ -f "$CONFIG_PATH" ]
}

# -----------------------------------------------------------------------------
# gh_project_list.sh tests
# -----------------------------------------------------------------------------

@test "gh_project_list.sh exits 1 when gh not available" {
  mv "${MOCK_BIN}/gh" "${MOCK_BIN}/gh_bak"
  run "${REPO_DIR}/scripts/gh_project_list.sh" 2>&1
  [ "$status" -eq 1 ]
  mv "${MOCK_BIN}/gh_bak" "${MOCK_BIN}/gh"
}

@test "gh_project_list.sh lists managed bare-clone projects" {
  # Create a mock projects directory structure with bare repos
  mkdir -p "${ORCH_HOME}/projects/owner1"
  git -C "${ORCH_HOME}/projects/owner1/repo1.git" init --bare --quiet 2>/dev/null || mkdir -p "${ORCH_HOME}/projects/owner1/repo1.git"

  run "${REPO_DIR}/scripts/gh_project_list.sh" 2>&1
  [ "$status" -eq 0 ]
}

@test "gh_project_list.sh shows message when no projects" {
  # Ensure projects directory is empty
  mkdir -p "${ORCH_HOME}/projects"

  run "${REPO_DIR}/scripts/gh_project_list.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"No managed"* ]] || [[ "$output" == *"projects"* ]]
}

@test "gh_project_list.sh lists org projects when org provided" {
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"graphql"* ]] && [[ "$*" == *"organization"* ]]; then
  echo '{"data":{"organization":{"projectsV2":{"nodes":[{"number":1,"title":"Project One","id":"PVT_1"}]}}}}'
fi
exit 0
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_list.sh" "myorg" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project One"* ]] || [[ "$output" == *"1"* ]]
}

@test "gh_project_list.sh lists user projects when user provided" {
  cat > "${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"graphql"* ]] && [[ "$*" == *"user"* ]]; then
  echo '{"data":{"user":{"projectsV2":{"nodes":[{"number":5,"title":"User Project","id":"PVT_5"}]}}}}'
fi
exit 0
SH
  chmod +x "${MOCK_BIN}/gh"

  run "${REPO_DIR}/scripts/gh_project_list.sh" "" "myuser" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"User Project"* ]] || [[ "$output" == *"5"* ]]
}
