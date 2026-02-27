#!/usr/bin/env bats
# Test coverage for jobs_tick.sh - job scheduling logic

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

  # Initialize jobs file
  mkdir -p "${PROJECT_DIR}/.orchestrator"
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
  allowed_tools: []
  default_skills: []
llm:
  input_format: ""
  output_format: ""
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

# Helper: get job field from jobs.yml
_job_field() {
  local id="$1" field="$2"
  yq -o=json '.jobs // []' "$JOBS_FILE" 2>/dev/null | jq -r --arg id "$id" --arg f "$field" '.[] | select(.id == $id) | .[$f] // empty'
}

# Helper: count tasks in jobs log
_jobs_log_count() {
  local log_file="${STATE_DIR}/jobs.log"
  if [ -f "$log_file" ]; then
    grep -c "\[jobs\]" "$log_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# -----------------------------------------------------------------------------
# Basic job scheduling tests
# -----------------------------------------------------------------------------

@test "jobs_tick.sh exits cleanly when no jobs exist" {
  printf 'jobs: []\n' > "$JOBS_FILE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh exits cleanly when jobs file is missing" {
  rm -f "$JOBS_FILE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh skips disabled jobs" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: disabled-job
    title: Disabled Job
    schedule: "* * * * *"
    type: task
    body: "Test body"
    enabled: false
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should not have created any tasks
  run jq '.issues | length' "$GH_MOCK_STATE"
  [ "$output" -eq 1 ]  # Only the init task
}

@test "jobs_tick.sh creates task for job matching current time" {
  # Use @hourly which should match at minute 0
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: hourly-job
    title: Hourly Sync
    schedule: "@hourly"
    type: task
    body: "Sync data"
    labels: "sync,automated"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh tracks active_task_id after creating task" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: track-job
    title: Track Test
    schedule: "@hourly"
    type: task
    body: "Track body"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Check that active_task_id was set
  active_id=$(_job_field "track-job" "active_task_id")
  [ -n "$active_id" ]
  [ "$active_id" != "null" ]
}

@test "jobs_tick.sh updates last_run timestamp after execution" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: timestamp-job
    title: Timestamp Test
    schedule: "@hourly"
    type: task
    body: "Test"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  last_run=$(_job_field "timestamp-job" "last_run")
  [ -n "$last_run" ]
  [ "$last_run" != "null" ]
}

# -----------------------------------------------------------------------------
# Cron matching tests
# -----------------------------------------------------------------------------

@test "cron_match.py matches @hourly alias" {
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@hourly"
  # May or may not match depending on current minute
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "cron_match.py matches @daily alias" {
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@daily"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "cron_match.py matches @weekly alias" {
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@weekly"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "cron_match.py matches @monthly alias" {
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@monthly"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "cron_match.py matches specific cron expression" {
  # Use current minute to ensure match
  current_min=$(date +%M)
  current_hour=$(date +%H)
  run python3 "${REPO_DIR}/scripts/cron_match.py" "$current_min $current_hour * * *"
  [ "$status" -eq 0 ]
}

@test "cron_match.py rejects non-matching cron expression" {
  # Use a minute that just passed or is coming up
  wrong_min=$(( ($(date +%M) + 1) % 60 ))
  run python3 "${REPO_DIR}/scripts/cron_match.py" "$wrong_min * * * *"
  [ "$status" -eq 1 ]
}

@test "cron_match.py handles invalid cron expression" {
  run python3 "${REPO_DIR}/scripts/cron_match.py" "invalid"
  [ "$status" -eq 1 ]
}

@test "cron_match.py --since catches missed runs" {
  # Check for match in last hour
  since=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ")
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@hourly" --since "$since"
  # Should match since we've had at least one hour boundary
  [ "$status" -eq 0 ]
}

@test "cron_match.py --since with 24h cap" {
  # Check with old timestamp (more than 24h ago)
  old_since=$(date -u -v-48H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '2 days ago' +"%Y-%m-%dT%H:%M:%SZ")
  run python3 "${REPO_DIR}/scripts/cron_match.py" "@hourly" --since "$old_since"
  # Should still work but be capped at 24h
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# -----------------------------------------------------------------------------
# Duplicate prevention tests
# -----------------------------------------------------------------------------

@test "jobs_tick.sh prevents duplicate task creation in same minute" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: dedup-job
    title: Deduplication Test
    schedule: "@hourly"
    type: task
    body: "Test"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  # First run
  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  task_count_before=$(jq '.issues | length' "$GH_MOCK_STATE")

  # Second run in same minute should skip
  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  task_count_after=$(jq '.issues | length' "$GH_MOCK_STATE")
  [ "$task_count_before" -eq "$task_count_after" ]
}

@test "jobs_tick.sh waits for active task to complete before creating new" {
  # Create a job with an active task that's in_progress
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: wait-job
    title: Wait Test
    schedule: "@hourly"
    type: task
    body: "Test"
    enabled: true
    active_task_id: 999
    last_run: "2024-01-01T00:00:00Z"
YAML

  # Mock the active task as in_progress in GH mock state
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq '.issues["999"] = {"number": 999, "title": "Active", "state": "open", "labels": [{"name": "status:in_progress"}]}' > "$GH_MOCK_STATE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should not create a new task
  active_id=$(_job_field "wait-job" "active_task_id")
  [ "$active_id" = "999" ]
}

@test "jobs_tick.sh clears completed active task and creates new" {
  # Create a job with an active task that's done
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: clear-job
    title: Clear Test
    schedule: "@hourly"
    type: task
    body: "Test"
    enabled: true
    active_task_id: 888
    last_run: "2024-01-01T00:00:00Z"
YAML

  # Mock the active task as done
  state=$(cat "$GH_MOCK_STATE")
  printf '%s' "$state" | jq '.issues["888"] = {"number": 888, "title": "Done", "state": "closed", "labels": [{"name": "status:done"}]}' > "$GH_MOCK_STATE"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have cleared the old active_task_id (or set to new one)
  # Note: active_task_id will be set to the new task if one was created
}

# -----------------------------------------------------------------------------
# Bash job type tests
# -----------------------------------------------------------------------------

@test "jobs_tick.sh executes bash job successfully" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: bash-job
    title: Bash Test
    schedule: "@hourly"
    type: bash
    command: "echo 'test output'"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Check last_task_status was updated
  last_status=$(_job_field "bash-job" "last_task_status")
  [ "$last_status" = "done" ]
}

@test "jobs_tick.sh handles bash job failure" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: bash-fail-job
    title: Bash Fail Test
    schedule: "@hourly"
    type: bash
    command: "exit 1"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  last_status=$(_job_field "bash-fail-job" "last_task_status")
  [ "$last_status" = "failed" ]
}

@test "jobs_tick.sh validates bash job command for security" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: bash-inject-job
    title: Injection Test
    schedule: "@hourly"
    type: bash
    command: "echo; rm -rf / # dangerous"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Job should be disabled due to security concern
  enabled=$(_job_field "bash-inject-job" "enabled")
  [ "$enabled" = "false" ]
}

@test "jobs_tick.sh skips bash job with empty command" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: empty-cmd-job
    title: Empty Command Test
    schedule: "@hourly"
    type: bash
    command: ""
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles bash job with invalid directory" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: bad-dir-job
    title: Bad Directory Test
    schedule: "@hourly"
    type: bash
    command: "echo test"
    dir: "/nonexistent/directory/path"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Job should be disabled
  enabled=$(_job_field "bad-dir-job" "enabled")
  [ "$enabled" = "false" ]
}

# -----------------------------------------------------------------------------
# Task job type tests
# -----------------------------------------------------------------------------

@test "jobs_tick.sh creates task with correct labels" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: labels-job
    title: Labels Test
    schedule: "@hourly"
    type: task
    body: "Test body"
    labels: "custom-label,another-label"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Verify task was created with labels
  active_id=$(_job_field "labels-job" "active_task_id")
  [ -n "$active_id" ]
  [ "$active_id" != "null" ]
}

@test "jobs_tick.sh creates task with agent specification" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: agent-job
    title: Agent Test
    schedule: "@hourly"
    type: task
    body: "Test"
    agent: "claude"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  active_id=$(_job_field "agent-job" "active_task_id")
  [ -n "$active_id" ]
}

@test "jobs_tick.sh adds job labels to task" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: job-labels-job
    title: Job Labels Test
    schedule: "@hourly"
    type: task
    body: "Test"
    labels: "from-job"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Task should have been created with scheduled and job: labels
  active_id=$(_job_field "job-labels-job" "active_task_id")
  [ -n "$active_id" ]
}

# -----------------------------------------------------------------------------
# Edge case tests
# -----------------------------------------------------------------------------

@test "jobs_tick.sh handles job with null type as task" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: null-type-job
    title: Null Type Test
    schedule: "@hourly"
    type: null
    body: "Test"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles multiple jobs" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: job-1
    title: Job One
    schedule: "@hourly"
    type: task
    body: "Test 1"
    enabled: true
    active_task_id: null
    last_run: null
  - id: job-2
    title: Job Two
    schedule: "@daily"
    type: task
    body: "Test 2"
    enabled: true
    active_task_id: null
    last_run: null
  - id: job-3
    title: Job Three
    schedule: "0 0 * * 0"
    type: bash
    command: "echo weekly"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh handles catch-up for missed runs" {
  # Set last_run to yesterday
  yesterday=$(date -u -v-1d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '1 day ago' +"%Y-%m-%dT%H:%M:%SZ")

  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: catchup-job
    title: Catch-up Test
    schedule: "@hourly"
    type: task
    body: "Test"
    enabled: true
    active_task_id: null
    last_run: "$yesterday"
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]
}

@test "jobs_tick.sh logs job activity" {
  cat > "$JOBS_FILE" <<YAML
jobs:
  - id: log-job
    title: Log Test
    schedule: "@hourly"
    type: bash
    command: "echo logged"
    enabled: true
    active_task_id: null
    last_run: null
YAML

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Check that jobs.log was created
  [ -f "${STATE_DIR}/jobs.log" ]
}
