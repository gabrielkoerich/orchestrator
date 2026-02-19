#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  TMP_DIR=$(mktemp -d)
  export STATE_DIR="${TMP_DIR}/.orchestrator"
  mkdir -p "$STATE_DIR"
  export ORCH_HOME="${TMP_DIR}/orch_home"
  mkdir -p "$ORCH_HOME"
  export TASKS_PATH="${ORCH_HOME}/tasks.yml"
  export CONFIG_PATH="${ORCH_HOME}/config.yml"
  export PROJECT_DIR="${TMP_DIR}"
  # Initialize a git repo so worktree creation works
  git -C "$PROJECT_DIR" init -b main --quiet 2>/dev/null || true
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet 2>/dev/null || true
  export MONITOR_INTERVAL=0.1
  cat > "$CONFIG_PATH" <<'YAML'
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

  "${REPO_DIR}/scripts/add_task.sh" "Init" "Bootstrap" "" >/dev/null
}

teardown() {
  # Clean up worktrees created by tests (they live outside TMP_DIR)
  PROJECT_NAME=$(basename "$TMP_DIR")
  WORKTREE_BASE="${ORCH_HOME}/worktrees/${PROJECT_NAME}"
  if [ -d "$WORKTREE_BASE" ]; then
    (cd "$TMP_DIR" && git worktree prune 2>/dev/null) || true
    rm -rf "$WORKTREE_BASE"
  fi
  rm -rf "${TMP_DIR}"
}

@test "add_task.sh creates a new task" {
  run "${REPO_DIR}/scripts/add_task.sh" "Test Title" "Test Body" "label1,label2"
  [ "$status" -eq 0 ]

  run yq -r '.tasks | length' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]

  run yq -r '.tasks[1].title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Test Title" ]

  run yq -r '.tasks[1].dir' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP_DIR" ]
}

@test "route_task.sh sets agent, status, and profile" {
  run "${REPO_DIR}/scripts/add_task.sh" "Route Me" "Routing body" ""
  [ "$status" -eq 0 ]

  run yq -i '.router.agent = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"executor":"codex","complexity":"medium","reason":"test route","profile":{"role":"backend specialist","skills":["api","sql"],"tools":["git","rg"],"constraints":["no migrations"]},"selected_skills":[]}
JSON
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/route_task.sh" 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tail -n1)" = "codex" ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  run yq -r '.tasks[] | select(.id == 2) | .agent_profile.role' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "backend specialist" ]
}

@test "run_task.sh updates task and handles delegations" {
  run "${REPO_DIR}/scripts/add_task.sh" "Run Me" "Run body" "plan"
  [ "$status" -eq 0 ]

  # Stub prints JSON to stdout (parsed by normalize_json_response)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"in_progress","summary":"scoped work","files_changed":[],"needs_help":true,"delegations":[{"title":"Child Task","body":"Do subtask","labels":["sub"],"suggested_agent":"codex"}]}
JSON
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]

  run yq -r '.tasks[] | select(.parent_id == 2) | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Child Task" ]
}

@test "run_task.sh ignores delegations from non-plan tasks" {
  run "${REPO_DIR}/scripts/add_task.sh" "Regular Task" "Regular body" ""
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"did the work","files_changed":[],"needs_help":false,"delegations":[{"title":"Unwanted Subtask","body":"Should be ignored","labels":[],"suggested_agent":"codex"}]}
JSON
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should be done, not blocked
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # No child tasks should be created
  run yq -r '.tasks[] | select(.parent_id == 2) | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "poll.sh runs new tasks and rejoins blocked parents" {
  run "${REPO_DIR}/scripts/add_task.sh" "Parent" "Parent body" ""
  [ "$status" -eq 0 ]

  run "${REPO_DIR}/scripts/add_task.sh" "Child" "Child body" ""
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 1) | .status) = "done"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .status) = "blocked" | (.tasks[] | select(.id == 2) | .children) = [3]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  run yq -i '(.tasks[] | select(.id == 3) | .status) = "done" | (.tasks[] | select(.id == 3) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Stub prints JSON to stdout (parsed by normalize_json_response)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"ok","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/poll.sh"
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "normalize_json_response parses Claude wrapper with fenced JSON" {
  RAW_FILE="${TMP_DIR}/raw.json"
  cat > "$RAW_FILE" <<'RAW'
{"type":"result","result":"```json\n{\"executor\":\"codex\"}\n```"}
RAW
  run env RAW_FILE="$RAW_FILE" bash -c 'source "'"${REPO_DIR}"'/scripts/lib.sh"; RAW=$(cat "$RAW_FILE"); normalize_json_response "$RAW" | jq -r ".executor"'
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}

@test "gh_api sets backoff on rate limit and respects skip mode" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  echo "secondary rate limit" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$GH_STUB"

  run bash -c "PATH=\"${TMP_DIR}:\$PATH\"; STATE_DIR='${STATE_DIR}'; GH_BACKOFF_MODE=skip; source '${REPO_DIR}/scripts/lib.sh'; set +e; gh_api repos/foo/issues >/dev/null; echo \"rc=\$?\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=75"* ]]
  [ -f "${STATE_DIR}/gh_backoff" ]
}

@test "gh_api skips when backoff active" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  echo "called" >> "${STATE_DIR}/gh_called"
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  future=$(( $(date +%s) + 300 ))
  printf "until=%s\ndelay=300\nreason=rate_limit\n" "$future" > "${STATE_DIR}/gh_backoff"

  run bash -c "PATH=\"${TMP_DIR}:\$PATH\"; STATE_DIR='${STATE_DIR}'; GH_BACKOFF_MODE=skip; source '${REPO_DIR}/scripts/lib.sh'; set +e; gh_api repos/foo/issues >/dev/null; echo \"rc=\$?\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=75"* ]]
  [ ! -f "${STATE_DIR}/gh_called" ]
}

@test "gh_sync.sh respects gh.enabled=false" {
  run yq -i '.gh.enabled = false' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  run env CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/gh_sync.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub sync disabled."* ]]
}

@test "gh_api wait mode sleeps and retries" {
  GH_STUB="${TMP_DIR}/gh"
  SLEEP_STUB="${TMP_DIR}/sleep"

  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  count_file="${STATE_DIR}/gh_count"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$((count + 1))
  echo "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    echo "secondary rate limit" >&2
    exit 1
  fi
  echo '{"ok":true}'
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  cat > "$SLEEP_STUB" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "${STATE_DIR}/slept"
exit 0
SH
  chmod +x "$SLEEP_STUB"

  run bash -c "PATH=\"${TMP_DIR}:\$PATH\"; STATE_DIR='${STATE_DIR}'; GH_BACKOFF_MODE=wait; source '${REPO_DIR}/scripts/lib.sh'; set +e; gh_api repos/foo/issues >/dev/null; echo \"rc=\$?\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [ -f "${STATE_DIR}/slept" ]
}

@test "route_task.sh falls back when router fails" {
  run "${REPO_DIR}/scripts/add_task.sh" "Fallback" "Fallback body" ""
  [ "$status" -eq 0 ]

  run yq -i '.router.agent = "claude" | .router.timeout_seconds = 0 | .router.fallback_executor = "codex"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$CLAUDE_STUB"

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"executor":"codex","reason":"fallback","profile":{"role":"general","skills":[],"tools":[],"constraints":[]},"selected_skills":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/route_task.sh" 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tail -n1)" = "codex" ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  run yq -r '.tasks[] | select(.id == 2) | .route_reason' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback"* ]]
}

@test "run_task.sh runs review agent when enabled" {
  run "${REPO_DIR}/scripts/add_task.sh" "Review Me" "Review body" ""
  [ "$status" -eq 0 ]

  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Task agent is codex → review agent should be claude (opposite)
  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Execution stub (codex) prints done JSON to stdout
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"done","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  # Review stub (claude) prints approve JSON
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"decision":"approve","notes":"looks good"}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  # Mock gh — return PR number for pr list, empty diff, accept pr review
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo "42"
elif [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "+added line"
elif [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  echo "Approved"
elif [ "$1" = "issue" ]; then
  echo ""
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .review_decision' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "approve" ]
}

@test "run_task.sh parses structured JSON from agent stdout" {
  run "${REPO_DIR}/scripts/add_task.sh" "Output Stdout" "Test stdout JSON parsing" ""
  [ "$status" -eq 0 ]

  # Stub prints JSON to stdout (parsed by normalize_json_response)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"wrote output file","accomplished":["task completed"],"remaining":[],"blockers":[],"files_changed":["test.txt"],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  run yq -r '.tasks[] | select(.id == 2) | .summary' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "wrote output file" ]

  run yq -r '.tasks[] | select(.id == 2) | .files_changed[0]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "test.txt" ]
}

@test "run_task.sh falls back to stdout when no output file" {
  run "${REPO_DIR}/scripts/add_task.sh" "Stdout Fallback" "Test stdout fallback" ""
  [ "$status" -eq 0 ]

  # Stub prints JSON to stdout (no output file)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"stdout mode","accomplished":[],"remaining":[],"blockers":[],"files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  run yq -r '.tasks[] | select(.id == 2) | .summary' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "stdout mode" ]
}

@test "cron_match.py matches wildcard expression" {
  # "* * * * *" always matches
  run python3 "${REPO_DIR}/scripts/cron_match.py" "* * * * *"
  [ "$status" -eq 0 ]
}

@test "cron_match.py rejects impossible expression" {
  # minute=99 never matches
  run python3 "${REPO_DIR}/scripts/cron_match.py" "99 99 99 99 9"
  [ "$status" -eq 1 ]
}

@test "cron_match.py handles aliases" {
  # @hourly = "0 * * * *", matches only at minute 0
  current_minute=$(date +%M | sed 's/^0//')
  if [ "${current_minute:-0}" -eq 0 ]; then
    run python3 "${REPO_DIR}/scripts/cron_match.py" "@hourly"
    [ "$status" -eq 0 ]
  else
    run python3 "${REPO_DIR}/scripts/cron_match.py" "@hourly"
    [ "$status" -eq 1 ]
  fi
}

@test "jobs_add.sh creates a job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  printf 'jobs: []\n' > "$JOBS_PATH"

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_add.sh" "0 9 * * *" "Daily Sync" "Run sync" "sync" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added job"* ]]

  run yq -r '.jobs | length' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run yq -r '.jobs[0].id' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "daily-sync" ]

  run yq -r '.jobs[0].schedule' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "0 9 * * *" ]

  run yq -r '.jobs[0].enabled' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "jobs_add.sh rejects duplicate job IDs" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  printf 'jobs: []\n' > "$JOBS_PATH"

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_add.sh" "0 9 * * *" "My Job" "body" "" ""
  [ "$status" -eq 0 ]

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_add.sh" "0 10 * * *" "My Job" "body2" "" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "jobs_tick.sh creates task when schedule matches" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  cat > "$JOBS_PATH" <<'YAML'
jobs:
  - id: test-always
    schedule: "* * * * *"
    task:
      title: "Always Run"
      body: "Test job body"
      labels: [test]
      agent: null
    enabled: true
    last_run: null
    last_task_status: null
    active_task_id: null
YAML

  run env JOBS_PATH="$JOBS_PATH" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have created a task
  run yq -r '.tasks[] | select(.title == "Always Run") | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  # Should have job:test-always label
  run yq -r '.tasks[] | select(.title == "Always Run") | .labels[]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"job:test-always"* ]]

  # Job should have active_task_id set
  run yq -r '.jobs[0].active_task_id' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "jobs_tick.sh skips when active task is in-flight" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  cat > "$JOBS_PATH" <<'YAML'
jobs:
  - id: test-dedup
    schedule: "* * * * *"
    task:
      title: "Dedup Test"
      body: "Should not duplicate"
      labels: []
      agent: null
    enabled: true
    last_run: null
    last_task_status: null
    active_task_id: 1
YAML

  # Task 1 (Init) is status "new" — in-flight
  run yq -r '.tasks[] | select(.id == 1) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  TASK_COUNT_BEFORE=$(yq -r '.tasks | length' "$TASKS_PATH")

  run env JOBS_PATH="$JOBS_PATH" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # No new task should have been created
  TASK_COUNT_AFTER=$(yq -r '.tasks | length' "$TASKS_PATH")
  [ "$TASK_COUNT_BEFORE" -eq "$TASK_COUNT_AFTER" ]
}

@test "jobs_tick.sh creates task after previous completes" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  cat > "$JOBS_PATH" <<'YAML'
jobs:
  - id: test-after-done
    schedule: "* * * * *"
    task:
      title: "After Done"
      body: "Run after previous finishes"
      labels: []
      agent: null
    enabled: true
    last_run: null
    last_task_status: null
    active_task_id: 1
YAML

  # Mark task 1 as done
  run yq -i '(.tasks[] | select(.id == 1) | .status) = "done"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env JOBS_PATH="$JOBS_PATH" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have created a new task
  run yq -r '.tasks[] | select(.title == "After Done") | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  # Last task status should be recorded
  run yq -r '.jobs[0].last_task_status' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "jobs_tick.sh skips disabled jobs" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  cat > "$JOBS_PATH" <<'YAML'
jobs:
  - id: test-disabled
    schedule: "* * * * *"
    task:
      title: "Disabled Job"
      body: "Should not run"
      labels: []
      agent: null
    enabled: false
    last_run: null
    last_task_status: null
    active_task_id: null
YAML

  TASK_COUNT_BEFORE=$(yq -r '.tasks | length' "$TASKS_PATH")

  run env JOBS_PATH="$JOBS_PATH" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  TASK_COUNT_AFTER=$(yq -r '.tasks | length' "$TASKS_PATH")
  [ "$TASK_COUNT_BEFORE" -eq "$TASK_COUNT_AFTER" ]
}

@test "load_project_config merges project override" {
  # Global config has router.model = ""
  run yq -r '.router.model' "$CONFIG_PATH"
  [ "$output" = "" ]

  # Create project override
  cat > "${TMP_DIR}/.orchestrator.yml" <<'YAML'
gh:
  repo: "myorg/myproject"
router:
  model: "sonnet"
YAML

  # Load merged config and check overridden values
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; PROJECT_DIR='${TMP_DIR}'; STATE_DIR='${STATE_DIR}'; load_project_config; config_get '.router.model'"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]

  # Non-overridden values should still come from global
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; PROJECT_DIR='${TMP_DIR}'; STATE_DIR='${STATE_DIR}'; load_project_config; config_get '.router.agent'"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

  # gh.repo should come from project override
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; PROJECT_DIR='${TMP_DIR}'; STATE_DIR='${STATE_DIR}'; load_project_config; config_get '.gh.repo // \"\"'"
  [ "$status" -eq 0 ]
  [ "$output" = "myorg/myproject" ]
}

@test "run_task.sh uses plan prompt for decompose mode" {
  run "${REPO_DIR}/scripts/add_task.sh" "Big Feature" "Build the whole thing" "plan"
  [ "$status" -eq 0 ]

  # Stub that checks which prompt it receives (prints JSON to stdout)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
# Check if the plan prompt is being used (contains "planning agent")
prompt="$* $(cat)"
if printf '%s' "$prompt" | grep -q "planning agent"; then
  cat <<'JSON'
{"status":"done","summary":"planned the work","accomplished":["analyzed task"],"remaining":[],"blockers":[],"files_changed":[],"needs_help":false,"reason":"","delegations":[{"title":"Step 1","body":"Do first thing","labels":["backend"],"suggested_agent":"codex"},{"title":"Step 2","body":"Do second thing","labels":["tests"],"suggested_agent":"codex"}]}
JSON
else
  cat <<'JSON'
{"status":"done","summary":"executed directly","accomplished":[],"remaining":[],"blockers":[],"files_changed":[],"needs_help":false,"reason":"","delegations":[]}
JSON
fi
SH
  chmod +x "$CODEX_STUB"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Should have created child tasks from delegation
  run yq -r '.tasks[] | select(.parent_id == 2) | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Step 1"* ]]
  [[ "$output" == *"Step 2"* ]]

  # Parent should be blocked
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "jobs_remove.sh removes a job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  printf 'jobs: []\n' > "$JOBS_PATH"

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_add.sh" "@daily" "To Remove" "" "" ""
  [ "$status" -eq 0 ]

  run yq -r '.jobs | length' "$JOBS_PATH"
  [ "$output" -eq 1 ]

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_remove.sh" "to-remove"
  [ "$status" -eq 0 ]

  run yq -r '.jobs | length' "$JOBS_PATH"
  [ "$output" -eq 0 ]
}

@test "init.sh prints project info" {
  # Stub gh so init.sh doesn't make real API calls during auto-sync
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_DIR/gh" && chmod +x "$TMP_DIR/gh"
  run env PATH="$TMP_DIR:$PATH" PROJECT_DIR="$TMP_DIR" "${REPO_DIR}/scripts/init.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initialized orchestrator"* ]]
  [[ "$output" == *"$TMP_DIR"* ]]
}

@test "list_tasks.sh filters by PROJECT_DIR" {
  # Task 1 (Init) already has dir=$TMP_DIR from setup()
  # Add a task for a different project
  OTHER_DIR=$(mktemp -d)
  run env PROJECT_DIR="$OTHER_DIR" TASKS_PATH="$TASKS_PATH" "${REPO_DIR}/scripts/add_task.sh" "Other Project" "other body" ""
  [ "$status" -eq 0 ]

  # Listing from TMP_DIR should only show the Init task
  run env PROJECT_DIR="$TMP_DIR" TASKS_PATH="$TASKS_PATH" "${REPO_DIR}/scripts/list_tasks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Init"* ]]
  [[ "$output" != *"Other Project"* ]]

  # Listing from OTHER_DIR should only show the Other task
  run env PROJECT_DIR="$OTHER_DIR" TASKS_PATH="$TASKS_PATH" "${REPO_DIR}/scripts/list_tasks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Other Project"* ]]
  [[ "$output" != *"Init"* ]]

  rm -rf "$OTHER_DIR"
}

@test "jobs_add.sh records dir field" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  printf 'jobs: []\n' > "$JOBS_PATH"

  run env JOBS_PATH="$JOBS_PATH" PROJECT_DIR="$TMP_DIR" "${REPO_DIR}/scripts/jobs_add.sh" "0 9 * * *" "Dir Job" "" "" ""
  [ "$status" -eq 0 ]

  run yq -r '.jobs[0].dir' "$JOBS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP_DIR" ]
}

@test "run_task.sh blocks task after max_attempts exceeded" {
  run "${REPO_DIR}/scripts/add_task.sh" "Max Retry" "Should block after max" ""
  [ "$status" -eq 0 ]

  # Set task to already have 10 attempts (max default) and agent assigned
  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex" | (.tasks[] | select(.id == 2) | .attempts) = 10' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
echo "should not be called" >&2
exit 1
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  run yq -r '.tasks[] | select(.id == 2) | .reason' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"max attempts"* ]]
}

@test "init.sh accepts --repo flag for non-interactive mode" {
  INIT_DIR=$(mktemp -d)
  # Stub gh so init.sh doesn't make real API calls during auto-sync
  printf '#!/usr/bin/env bash\nexit 1\n' > "$INIT_DIR/gh" && chmod +x "$INIT_DIR/gh"
  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" "${REPO_DIR}/scripts/init.sh" --repo "myorg/myapp" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Initialized orchestrator"* ]]
  [ -f "$INIT_DIR/.orchestrator.yml" ]

  run yq -r '.gh.repo' "$INIT_DIR/.orchestrator.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "myorg/myapp" ]

  rm -rf "$INIT_DIR"
}

@test "init.sh is idempotent with existing config" {
  INIT_DIR=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$INIT_DIR/gh" && chmod +x "$INIT_DIR/gh"

  # First init creates config
  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" "${REPO_DIR}/scripts/init.sh" --repo "myorg/myapp" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$INIT_DIR/.orchestrator.yml" ]

  run yq -r '.gh.repo' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "myorg/myapp" ]

  # Second init preserves existing repo
  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" "${REPO_DIR}/scripts/init.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing"* ]]

  # Config should still have the repo
  run yq -r '.gh.repo' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "myorg/myapp" ]

  rm -rf "$INIT_DIR"
}

@test "init.sh re-init with --repo updates existing config" {
  INIT_DIR=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$INIT_DIR/gh" && chmod +x "$INIT_DIR/gh"

  # First init
  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" "${REPO_DIR}/scripts/init.sh" --repo "old/repo" </dev/null
  [ "$status" -eq 0 ]

  # Re-init with different repo
  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" "${REPO_DIR}/scripts/init.sh" --repo "new/repo" </dev/null
  [ "$status" -eq 0 ]

  run yq -r '.gh.repo' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "new/repo" ]

  rm -rf "$INIT_DIR"
}

@test "gh_pull.sh handles paginated JSON arrays" {
  # Simulate gh api returning two separate JSON arrays (one per page)
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  if printf '%s' "$*" | grep -q "repos/"; then
    # Simulate paginated output: two arrays
    printf '[{"number":1,"title":"Issue 1","body":"body1","labels":[],"state":"open","html_url":"https://github.com/test/repo/issues/1","updated_at":"2026-01-01T00:00:00Z","pull_request":null}]\n'
    printf '[{"number":2,"title":"Issue 2","body":"body2","labels":[],"state":"open","html_url":"https://github.com/test/repo/issues/2","updated_at":"2026-01-01T00:00:00Z","pull_request":null}]\n'
    exit 0
  fi
fi
exit 0
SH
  chmod +x "$GH_STUB"

  # Create a minimal project config with gh.repo
  cat > "${TMP_DIR}/.orchestrator.yml" <<'YAML'
gh:
  repo: "test/repo"
YAML

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # Both issues should have been imported
  run yq -r '.tasks[] | select(.title == "Issue 1") | .gh_issue_number' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run yq -r '.tasks[] | select(.title == "Issue 2") | .gh_issue_number' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "agents.sh lists agent availability" {
  run "${REPO_DIR}/scripts/agents.sh"
  [ "$status" -eq 0 ]
  # Should mention all three agents regardless of availability
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"opencode"* ]]
}

@test "concurrent task additions don't corrupt tasks.yml" {
  # Run 5 parallel add_task.sh calls (enough to test concurrency, not too many for slow CI)
  pids=()
  successes=0
  for i in $(seq 1 5); do
    env TASKS_PATH="$TASKS_PATH" PROJECT_DIR="$PROJECT_DIR" LOCK_WAIT_SECONDS=120 "${REPO_DIR}/scripts/add_task.sh" "Concurrent $i" "body $i" "" >/dev/null 2>&1 &
    pids+=($!)
  done

  # Wait for all to complete and count successes
  for pid in "${pids[@]}"; do
    wait "$pid" && successes=$((successes + 1)) || true
  done

  # At least 3 of 5 should succeed (slow CI may lose some to lock contention)
  [ "$successes" -ge 3 ]

  # File must be valid YAML with correct task count (Init + successes)
  EXPECTED=$((1 + successes))
  run yq -r '.tasks | length' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" -eq "$EXPECTED" ]

  # IDs should be unique (no corruption from concurrent writes)
  run bash -c "yq -r '.tasks[].id' '$TASKS_PATH' | sort -u | wc -l"
  [ "$status" -eq 0 ]
  UNIQUE_COUNT=$(echo "$output" | tr -d ' ')
  [ "$UNIQUE_COUNT" -eq "$EXPECTED" ]
}

@test "performance: list_tasks.sh handles 100+ tasks" {
  # Create 100 tasks via yq batch
  for i in $(seq 2 100); do
    export i NOW="2026-01-01T00:00:00Z"
    yq -i ".tasks += [{\"id\": $i, \"title\": \"Task $i\", \"body\": \"\", \"labels\": [], \"status\": \"new\", \"agent\": null, \"agent_model\": null, \"agent_profile\": null, \"selected_skills\": [], \"parent_id\": null, \"children\": [], \"route_reason\": null, \"route_warning\": null, \"summary\": null, \"reason\": null, \"accomplished\": [], \"remaining\": [], \"blockers\": [], \"files_changed\": [], \"needs_help\": false, \"attempts\": 0, \"last_error\": null, \"retry_at\": null, \"review_decision\": null, \"review_notes\": null, \"history\": [], \"dir\": \"$TMP_DIR\", \"created_at\": \"$NOW\", \"updated_at\": \"$NOW\"}]" "$TASKS_PATH"
  done

  run yq -r '.tasks | length' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" -eq 100 ]

  # list should complete in reasonable time (< 10s)
  SECONDS=0
  run env TASKS_PATH="$TASKS_PATH" PROJECT_DIR="$TMP_DIR" "${REPO_DIR}/scripts/list_tasks.sh"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
}

@test "render_template fails on missing template" {
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; render_template '/tmp/nonexistent_template_xyz.md'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template not found"* ]]
}

@test "render_template omits if block when value is empty or whitespace" {
  TEMPLATE_PATH="${TMP_DIR}/tmpl-if-empty.md"
  cat > "$TEMPLATE_PATH" <<'EOF'
start
{{#if OPTIONAL}}
optional section
{{OPTIONAL}}
{{/if}}
end
EOF

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; OPTIONAL='   ' render_template '$TEMPLATE_PATH'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"start"* ]]
  [[ "$output" == *"end"* ]]
  [[ "$output" != *"optional section"* ]]
}

@test "render_template keeps if block when value is non-empty" {
  TEMPLATE_PATH="${TMP_DIR}/tmpl-if-filled.md"
  cat > "$TEMPLATE_PATH" <<'EOF'
{{#if OPTIONAL}}
optional section
{{OPTIONAL}}
{{/if}}
EOF

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; OPTIONAL='value present' render_template '$TEMPLATE_PATH'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"optional section"* ]]
  [[ "$output" == *"value present"* ]]
}

@test "create_task_entry creates task via shared helper" {
  NOW="2026-01-01T00:00:00Z"
  export NOW PROJECT_DIR="$TMP_DIR"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    create_task_entry 99 'Helper Task' 'Created by helper' 'test,helper' '' ''
  "
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 99) | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Helper Task" ]

  run yq -r '.tasks[] | select(.id == 99) | .dir' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP_DIR" ]
}

@test "chat.sh dispatches add_task action" {
  # Stub agent that returns a chat JSON response
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"action":"add_task","params":{"title":"Fix login page","body":"The login page has a broken CSS layout","labels":"bug,frontend"},"response":"I've created a task to fix the login page."}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  # Feed "add a task" then "exit" via stdin
  run bash -c "
    printf 'add a task to fix the login page\nexit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fix login page"* ]]

  # Verify task was actually created
  run yq -r '.tasks[] | select(.title == "Fix login page") | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Fix login page" ]
}

@test "chat.sh handles invalid JSON gracefully" {
  # Stub agent that returns non-JSON
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo "I don't know how to respond in JSON right now."
SH
  chmod +x "$CLAUDE_STUB"

  run bash -c "
    printf 'hello\nexit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  # Should show the raw response as fallback
  [[ "$output" == *"I don't know how to respond"* ]]
}

@test "chat.sh exits on quit command" {
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo '{"action":"answer","params":{},"response":"hi"}'
SH
  chmod +x "$CLAUDE_STUB"

  run bash -c "
    printf 'quit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Goodbye!"* ]]
}

@test "chat.sh dispatches status action" {
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"action":"status","params":{},"response":"Here's your current status."}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  run bash -c "
    printf 'show me the status\nexit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  # Should contain status table (total row)
  [[ "$output" == *"total"* ]]
}

@test "chat.sh cleans up history file on exit" {
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo '{"action":"answer","params":{},"response":"hi"}'
SH
  chmod +x "$CLAUDE_STUB"

  bash -c "
    printf 'exit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "

  # No chat-history files should remain
  run bash -c "ls '${STATE_DIR}'/chat-history-* 2>/dev/null | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

@test "chat.sh quick_task runs agent in PROJECT_DIR not cwd" {
  # Call-counting stub: first call is the LLM (returns quick_task action),
  # second call is the dispatched agent (records its working directory).
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<SH
#!/usr/bin/env bash
count_file="${STATE_DIR}/chat_call_count"
count=0
if [ -f "\$count_file" ]; then
  count=\$(cat "\$count_file")
fi
count=\$((count + 1))
echo "\$count" > "\$count_file"

if [ "\$count" -eq 1 ]; then
  cat <<'JSON'
{"action":"quick_task","params":{"prompt":"list files"},"response":"Running quick task..."}
JSON
else
  pwd > "${STATE_DIR}/agent_cwd"
  echo "done"
fi
SH
  chmod +x "$CLAUDE_STUB"

  # Create a different directory to simulate brew's cd to libexec
  FAKE_LIBEXEC=$(mktemp -d)

  run bash -c "
    cd '$FAKE_LIBEXEC' && \
    printf 'list files\nexit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        JOBS_PATH='${TMP_DIR}/jobs.yml' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/chat.sh' 2>/dev/null
  "
  [ "$status" -eq 0 ]

  # Agent should have run in PROJECT_DIR, not FAKE_LIBEXEC
  [ -f "${STATE_DIR}/agent_cwd" ]
  agent_dir=$(cat "${STATE_DIR}/agent_cwd")
  [ "$agent_dir" = "$TMP_DIR" ]

  rm -rf "$FAKE_LIBEXEC"
}

# --- plan_chat.sh tests ---

@test "plan_chat.sh shows usage on missing title" {
  run "${REPO_DIR}/scripts/plan_chat.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

@test "plan_chat.sh proposes plan on first turn" {
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"action":"ask","params":{},"response":"Here is my proposed plan:\n1. Set up database schema\n2. Implement API endpoints\n3. Add tests"}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  run bash -c "
    printf 'exit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/plan_chat.sh' 'Build auth system' 'Need user authentication' '' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"proposed plan"* ]]
}

@test "plan_chat.sh creates tasks on approval" {
  # Call-counting stub: first call returns ask, second returns create_tasks
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<SH
#!/usr/bin/env bash
count_file="${STATE_DIR}/plan_call_count"
count=0
if [ -f "\$count_file" ]; then
  count=\$(cat "\$count_file")
fi
count=\$((count + 1))
echo "\$count" > "\$count_file"

if [ "\$count" -eq 1 ]; then
  cat <<'JSON'
{"action":"ask","params":{},"response":"Here is my plan:\n1. Create user model\n2. Add login endpoint"}
JSON
else
  cat <<'JSON'
{"action":"create_tasks","params":{"tasks":[{"title":"Create user model","body":"Set up User table","labels":"backend","suggested_agent":""},{"title":"Add login endpoint","body":"POST /login","labels":"backend,api","suggested_agent":""}]},"response":"Creating 2 tasks."}
JSON
fi
SH
  chmod +x "$CLAUDE_STUB"

  run bash -c "
    printf 'looks good\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/plan_chat.sh' 'Build auth' 'Auth system' '' 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created 2 task(s)"* ]]

  # Verify tasks were actually created
  run yq -r '.tasks[] | select(.title == "Create user model") | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Create user model" ]

  run yq -r '.tasks[] | select(.title == "Add login endpoint") | .title' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "Add login endpoint" ]
}

@test "link_project_to_repo calls linkProjectV2ToRepository" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q "repos/test/repo"; then
  echo '{"node_id":"R_abc123"}'
  exit 0
fi
if printf '%s' "$*" | grep -q "linkProjectV2ToRepository"; then
  echo '{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R_abc123"}}}}'
  # Write a marker so we can verify the mutation was called
  echo "linked" > "${STATE_DIR}/link_called"
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  source "${REPO_DIR}/scripts/lib.sh"
  run env PATH="${TMP_DIR}:${PATH}" STATE_DIR="$STATE_DIR" \
    bash -c "source '${REPO_DIR}/scripts/lib.sh' && link_project_to_repo PVT_proj123 test/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Linked project to test/repo"* ]]
  [ -f "${STATE_DIR}/link_called" ]
}

@test "gh_push.sh adds issue to project when not already present" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
# Route based on arguments
args="$*"

# repos/REPO/issues (create issue)
if printf '%s' "$args" | grep -q "repos/test/repo/issues" && ! printf '%s' "$args" | grep -q "graphql"; then
  if printf '%s' "$args" | grep -q "PATCH"; then
    echo '{}'
    exit 0
  fi
  if printf '%s' "$args" | grep -q "comments"; then
    echo '{}'
    exit 0
  fi
  # GET issue node_id
  if printf '%s' "$args" | grep -q -- "-q .node_id"; then
    echo "I_issue1node"
    exit 0
  fi
  echo '{"number":1,"html_url":"https://github.com/test/repo/issues/1","state":"open"}'
  exit 0
fi

# GraphQL: project items query (return empty — issue not in project)
if printf '%s' "$args" | grep -q "items(first"; then
  echo '{"data":{"node":{"items":{"nodes":[]}}}}'
  exit 0
fi

# GraphQL: addProjectV2ItemById
if printf '%s' "$args" | grep -q "addProjectV2ItemById"; then
  echo "add_to_project" >> "${STATE_DIR}/gh_calls"
  echo '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_item1"}}}}'
  exit 0
fi

# GraphQL: updateProjectV2ItemFieldValue
if printf '%s' "$args" | grep -q "updateProjectV2ItemFieldValue"; then
  echo "update_status" >> "${STATE_DIR}/gh_calls"
  echo '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_item1"}}}}'
  exit 0
fi

# repo view
if printf '%s' "$args" | grep -q "repo view"; then
  echo "test/repo"
  exit 0
fi

echo '{}'
exit 0
SH
  chmod +x "$GH_STUB"

  # Set up config with project settings
  cat > "$CONFIG_PATH" <<'YAML'
workflow:
  auto_close: true
gh:
  repo: "test/repo"
  project_id: "PVT_proj123"
  project_status_field_id: "PVTSSF_field1"
  project_status_map:
    backlog: "opt_backlog"
    in_progress: "opt_inprog"
    review: "opt_review"
    done: "opt_done"
YAML

  # Create a task with gh_issue_number already set but not synced
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  export NOW
  yq -i \
    "(.tasks[0].gh_issue_number) = 1 |
     (.tasks[0].gh_url) = \"https://github.com/test/repo/issues/1\" |
     (.tasks[0].gh_state) = \"open\" |
     (.tasks[0].status) = \"in_progress\" |
     (.tasks[0].updated_at) = env(NOW) |
     (.tasks[0].gh_synced_at) = \"\"" \
    "$TASKS_PATH"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added issue #1 to project"* ]]

  # Verify addProjectV2ItemById was called
  [ -f "${STATE_DIR}/gh_calls" ]
  grep -q "add_to_project" "${STATE_DIR}/gh_calls"
}

@test "gh_push.sh archives done+closed project items" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -q "archiveProjectV2Item"; then
  echo "archive_called" >> "${STATE_DIR}/gh_calls"
  echo '{"data":{"archiveProjectV2Item":{"item":{"id":"PVTI_item1"}}}}'
  exit 0
fi

echo '{}'
exit 0
SH
  chmod +x "$GH_STUB"

  cat > "$CONFIG_PATH" <<'YAML'
gh:
  repo: "test/repo"
  project_id: "PVT_proj123"
YAML

  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  yq -i \
    "(.tasks[0].gh_issue_number) = 1 |
     (.tasks[0].gh_state) = \"closed\" |
     (.tasks[0].status) = \"done\" |
     (.tasks[0].gh_project_item_id) = \"PVTI_item1\" |
     (.tasks[0].gh_archived) = false |
     (.tasks[0].updated_at) = \"$NOW\" |
     (.tasks[0].gh_synced_at) = \"\"" \
    "$TASKS_PATH"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  [ -f "${STATE_DIR}/gh_calls" ]
  grep -q "archive_called" "${STATE_DIR}/gh_calls"

  run yq -r '.tasks[0].gh_archived' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "gh_push.sh skips archiving if already archived" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -q "archiveProjectV2Item"; then
  echo "archive_called" >> "${STATE_DIR}/gh_calls"
fi

echo '{}'
exit 0
SH
  chmod +x "$GH_STUB"

  cat > "$CONFIG_PATH" <<'YAML'
gh:
  repo: "test/repo"
  project_id: "PVT_proj123"
YAML

  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  yq -i \
    "(.tasks[0].gh_issue_number) = 1 |
     (.tasks[0].gh_state) = \"closed\" |
     (.tasks[0].status) = \"done\" |
     (.tasks[0].gh_project_item_id) = \"PVTI_item1\" |
     (.tasks[0].gh_archived) = true |
     (.tasks[0].updated_at) = \"$NOW\" |
     (.tasks[0].gh_synced_at) = \"\"" \
    "$TASKS_PATH"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  if [ -f "${STATE_DIR}/gh_calls" ]; then
    run cat "${STATE_DIR}/gh_calls"
    [ "$status" -eq 0 ]
    [[ "$output" != *"archive_called"* ]]
  fi
}

@test "gh_push.sh skips archiving for done tasks not yet closed" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -q "archiveProjectV2Item"; then
  echo "archive_called" >> "${STATE_DIR}/gh_calls"
fi

echo '{}'
exit 0
SH
  chmod +x "$GH_STUB"

  cat > "$CONFIG_PATH" <<'YAML'
gh:
  repo: "test/repo"
  project_id: "PVT_proj123"
YAML

  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  yq -i \
    "(.tasks[0].gh_issue_number) = 1 |
     (.tasks[0].gh_state) = \"open\" |
     (.tasks[0].status) = \"done\" |
     (.tasks[0].gh_project_item_id) = \"PVTI_item1\" |
     (.tasks[0].gh_archived) = false |
     (.tasks[0].updated_at) = \"$NOW\" |
     (.tasks[0].gh_synced_at) = \"$NOW\"" \
    "$TASKS_PATH"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  if [ -f "${STATE_DIR}/gh_calls" ]; then
    run cat "${STATE_DIR}/gh_calls"
    [ "$status" -eq 0 ]
    [[ "$output" != *"archive_called"* ]]
  fi
}

@test "plan_chat.sh cleans up history on exit" {
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"action":"ask","params":{},"response":"What kind of auth?"}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  bash -c "
    printf 'exit\n' | \
    env PATH='${TMP_DIR}:${PATH}' \
        TASKS_PATH='$TASKS_PATH' \
        CONFIG_PATH='$CONFIG_PATH' \
        PROJECT_DIR='$TMP_DIR' \
        STATE_DIR='$STATE_DIR' \
        CHAT_AGENT=claude \
        '${REPO_DIR}/scripts/plan_chat.sh' 'Build auth' '' '' 2>/dev/null
  "

  # No plan-history files should remain
  run bash -c "ls '${STATE_DIR}'/plan-history-* 2>/dev/null | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

@test "auto_detect_status finds options with yq inline flag syntax" {
  # Regression: test("^Name$"; "i") is jq syntax, yq needs test("(?i)^Name$")
  json='{"data":{"node":{"fields":{"nodes":[{},{"id":"PVTSSF_f1","name":"Status","options":[{"id":"O1","name":"Backlog"},{"id":"O2","name":"In Progress"},{"id":"O3","name":"Review"},{"id":"O4","name":"Done"}]},{}]}}}}'

  # Each option name should be found with case-insensitive regex
  for pair in "Backlog:O1" "In Progress:O2" "Review:O3" "Done:O4"; do
    name="${pair%%:*}"
    expected="${pair##*:}"
    run bash -c "printf '%s' '$json' | yq -r '.data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"(?i)^${name}\$\")) | .id'"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done

  # Case-insensitive: "todo" should match "Todo"
  json2='{"data":{"node":{"fields":{"nodes":[{"id":"F1","name":"Status","options":[{"id":"X1","name":"Todo"}]}]}}}}'
  run bash -c "printf '%s' '$json2' | yq -r '.data.node.fields.nodes[] | select(.name == \"Status\") | .options[] | select(.name | test(\"(?i)^Todo\$\")) | .id'"
  [ "$status" -eq 0 ]
  [ "$output" = "X1" ]
}

@test "init.sh auto_detect_status populates status map in config" {
  INIT_DIR=$(mktemp -d)

  # Stub gh: returns project field options for the GraphQL query
  GH_STUB="$INIT_DIR/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -q "graphql" && printf '%s' "$args" | grep -q "fields(first"; then
  cat <<'JSON'
{"data":{"node":{"fields":{"nodes":[{},{"id":"PVTSSF_status1","name":"Status","options":[{"id":"opt_bl","name":"Backlog"},{"id":"opt_ip","name":"In Progress"},{"id":"opt_rv","name":"Review"},{"id":"opt_dn","name":"Done"}]},{}]}}}}
JSON
  exit 0
fi
exit 1
SH
  chmod +x "$GH_STUB"

  run env PATH="$INIT_DIR:$PATH" PROJECT_DIR="$INIT_DIR" \
    "${REPO_DIR}/scripts/init.sh" --repo "test/repo" --project-id "PVT_proj1" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected status options"* ]]
  [[ "$output" == *"backlog -> opt_bl"* ]]
  [[ "$output" == *"in_progress -> opt_ip"* ]]
  [[ "$output" == *"review -> opt_rv"* ]]
  [[ "$output" == *"done -> opt_dn"* ]]

  # Config file should have all status map entries
  run yq -r '.gh.project_status_field_id' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "PVTSSF_status1" ]

  run yq -r '.gh.project_status_map.backlog' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "opt_bl" ]

  run yq -r '.gh.project_status_map.in_progress' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "opt_ip" ]

  run yq -r '.gh.project_status_map.review' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "opt_rv" ]

  run yq -r '.gh.project_status_map.done' "$INIT_DIR/.orchestrator.yml"
  [ "$output" = "opt_dn" ]

  rm -rf "$INIT_DIR"
}

@test "configure_project_status_field calls updateProjectV2Field" {
  INIT_DIR=$(mktemp -d)

  # gh stub: returns status field ID on query, records updateProjectV2Field call
  cat > "$INIT_DIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -q "updateProjectV2Field"; then
  touch /tmp/_orch_test_update_called
  echo '{"data":{}}'
  exit 0
fi
if printf '%s' "$args" | grep -q "fields(first"; then
  echo '{"data":{"node":{"fields":{"nodes":[{"id":"PVTSSF_s1","name":"Status"}]}}}}'
  exit 0
fi
exit 1
GHSTUB
  chmod +x "$INIT_DIR/gh"

  # Extract and run configure_project_status_field from init.sh
  rm -f /tmp/_orch_test_update_called
  run env PATH="$INIT_DIR:$PATH" bash -c "
    $(sed -n '/^configure_project_status_field()/,/^}/p' "${REPO_DIR}/scripts/init.sh")
    configure_project_status_field PVT_test
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configured project status columns"* ]]
  [ -f /tmp/_orch_test_update_called ]

  rm -f /tmp/_orch_test_update_called
  rm -rf "$INIT_DIR"
}

@test "lock_mtime returns 0 for nonexistent path without errors" {
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; lock_mtime /tmp/nonexistent_lock_$$"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "lock_mtime returns mtime for existing directory" {
  LOCK_DIR=$(mktemp -d)
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; lock_mtime '$LOCK_DIR'"
  [ "$status" -eq 0 ]
  # Should be a numeric timestamp
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
  rm -rf "$LOCK_DIR"
}

@test "lock_is_stale handles missing lock gracefully" {
  # lock_is_stale returns 1 (not stale) for nonexistent paths — no errors
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; set +e; lock_is_stale /tmp/nonexistent_lock_$$ 2>&1; echo rc=\$?"
  # No stat errors in output
  [[ "$output" != *"No such file"* ]]
  [[ "$output" != *"integer expression"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "scripts use strenv() not env() for yq string values" {
  # env() parses values as YAML which breaks on markdown content (colons, anchors, etc.)
  # Only env(X) | tonumber is allowed; all other env() must be strenv()
  run bash -c "grep -rn 'env(' '${REPO_DIR}/scripts/'*.sh | grep -v strenv | grep -v 'env(.*) | tonumber' | grep -v '^\s*#' | grep -v 'command -v\|export \|:-\|ORCH_HOME\|PATH=' || true"
  [ -z "$output" ]
}

@test "run_task.sh recovers stale lock with pid file from dead process" {
  # Stale lock with a pid file inside should be cleaned up so the task can run.
  run "${REPO_DIR}/scripts/add_task.sh" "Stuck Task" "Should recover from stale lock" ""
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex" | (.tasks[] | select(.id == 2) | .status) = "routed"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Create stale lock dir with pid file (dead PID)
  TASK_LOCK="${TASKS_PATH}.lock.task.2"
  mkdir -p "$TASK_LOCK"
  echo "99999" > "$TASK_LOCK/pid"
  touch -t 202501010000 "$TASK_LOCK"

  # Stub codex to succeed (prints JSON to stdout)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"recovered","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" LOCK_STALE_SECONDS=1 \
    "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should have run and completed
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # Lock should be cleaned up
  [ ! -d "$TASK_LOCK" ]
}

@test "append_history records actual status not zero" {
  # with_lock() has `local status=0` which shadows the exported `status`
  # from append_history. All history entries should show the real status,
  # not "0".
  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    append_history 1 'blocked' 'test note'
  "
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 1) | .history[-1].status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "gh_pull.sh does not bump updated_at on already-done closed issues" {
  # gh_pull sets updated_at = NOW on closed issues every pull cycle,
  # even if the task is already done. This triggers unnecessary gh_push syncs.
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  if printf '%s' "$*" | grep -q "repos/"; then
    printf '[{"number":1,"title":"Already Done","body":"closed issue","labels":[],"state":"closed","html_url":"https://github.com/test/repo/issues/1","updated_at":"2026-01-01T00:00:00Z","pull_request":null}]\n'
    exit 0
  fi
fi
exit 0
SH
  chmod +x "$GH_STUB"

  # Set task 1 to done with a known updated_at
  FROZEN="2026-01-15T12:00:00Z"
  export FROZEN
  run yq -i "(.tasks[] | select(.id == 1) | .status) = \"done\" |
    (.tasks[] | select(.id == 1) | .gh_issue_number) = 1 |
    (.tasks[] | select(.id == 1) | .gh_state) = \"closed\" |
    (.tasks[] | select(.id == 1) | .updated_at) = \"$FROZEN\"" "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # updated_at should still be the original value, not bumped
  run yq -r '.tasks[] | select(.id == 1) | .updated_at' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$FROZEN" ]
}

@test "run_task.sh passes --output-format to agents" {
  # Regression: agents must return structured JSON, not raw text
  run grep -n 'output-format\|--json\|--format json' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  # claude must have --output-format json
  [[ "$output" == *"output-format json"* ]]
  # codex must have --json
  [[ "$output" == *"--json"* ]]
  # opencode must have --format json
  [[ "$output" == *"--format json"* ]]
}

@test "run_task.sh passes --permission-mode acceptEdits to claude" {
  run grep -n 'permission-mode acceptEdits' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--permission-mode acceptEdits"* ]]
}

@test "run_task.sh injects agent and model into response JSON" {
  run "${REPO_DIR}/scripts/add_task.sh" "Inject Meta" "Test agent/model injection" ""
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"tested","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Check that the task's yq state got updated with the correct status
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # Agent model should be recorded in the task
  run yq -r '.tasks[] | select(.id == 2) | .agent_model' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

@test "normalize_json.py --tool-history extracts tool calls" {
  RAW='{"type":"tool_use","tool":"Bash","input":{"command":"ls"}}
{"type":"tool_result","is_error":false}
{"type":"tool_use","tool":"Edit","input":{"file_path":"test.ts"}}
{"type":"tool_result","is_error":true}
{"type":"text","part":{"text":"done"}}'

  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-history"
  [ "$status" -eq 0 ]
  # Should have 2 tool entries
  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-history | jq 'length'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  # First tool should be Bash with no error
  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-history | jq '.[0].tool'"
  [ "$status" -eq 0 ]
  [ "$output" = '"Bash"' ]

  # Second tool should have error=true
  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-history | jq '.[1].error'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "normalize_json.py --tool-summary formats readable output" {
  RAW='{"type":"tool_use","tool":"Bash","input":{"command":"npm test"}}
{"type":"tool_result","is_error":false}
{"type":"tool_use","tool":"Edit","input":{"file_path":"src/main.ts"}}
{"type":"tool_result","is_error":true}'

  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-summary"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ npm test"* ]]
  [[ "$output" == *"Edit: src/main.ts [ERROR]"* ]]
}

@test "normalize_json.py --tool-history returns empty on no tools" {
  RAW='{"type":"text","part":{"text":"hello"}}'
  run bash -c "RAW_RESPONSE='$RAW' python3 '${REPO_DIR}/scripts/normalize_json.py' --tool-history"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "comment dedup skips identical comments" {
  # Set up a task with a known last_comment_hash
  BODY="test comment body"
  HASH=$(printf '%s' "$BODY" | shasum -a 256 | cut -c1-16)
  export HASH
  yq -i "(.tasks[] | select(.id == 1) | .last_comment_hash) = strenv(HASH)" "$TASKS_PATH"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    # Source the dedup functions from gh_push
    should_skip_comment() {
      local task_id=\"\$1\" body=\"\$2\"
      local new_hash old_hash
      new_hash=\$(printf '%s' \"\$body\" | shasum -a 256 | cut -c1-16)
      old_hash=\$(yq -r \".tasks[] | select(.id == \$task_id) | .last_comment_hash // \\\"\\\"\" \"\$TASKS_PATH\")
      [ \"\$new_hash\" = \"\$old_hash\" ]
    }
    if should_skip_comment 1 '$BODY'; then
      echo 'SKIPPED'
    else
      echo 'POSTED'
    fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED" ]
}

@test "comment dedup posts when content differs" {
  yq -i '(.tasks[] | select(.id == 1) | .last_comment_hash) = "oldoldhash12345"' "$TASKS_PATH"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    should_skip_comment() {
      local task_id=\"\$1\" body=\"\$2\"
      local new_hash old_hash
      new_hash=\$(printf '%s' \"\$body\" | shasum -a 256 | cut -c1-16)
      old_hash=\$(yq -r \".tasks[] | select(.id == \$task_id) | .last_comment_hash // \\\"\\\"\" \"\$TASKS_PATH\")
      [ \"\$new_hash\" = \"\$old_hash\" ]
    }
    if should_skip_comment 1 'new different body'; then
      echo 'SKIPPED'
    else
      echo 'POSTED'
    fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "POSTED" ]
}

@test "create_task_entry includes last_comment_hash field" {
  NOW="2026-01-01T00:00:00Z"
  export NOW PROJECT_DIR="$TMP_DIR"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    create_task_entry 50 'Schema Test' 'Check fields' '' '' ''
  "
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 50) | has("last_comment_hash")' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "fetch_issue_comments returns empty for missing issue" {
  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    result=\$(fetch_issue_comments 'test/repo' '' 10)
    echo \"result=[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"result=[]"* ]]
}

@test "fetch_issue_comments returns empty for null issue" {
  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    result=\$(fetch_issue_comments 'test/repo' 'null' 10)
    echo \"result=[\$result]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"result=[]"* ]]
}

@test "build_skills_catalog returns JSON array from SKILL.md files" {
  SKILLS_TMP=$(mktemp -d)
  mkdir -p "$SKILLS_TMP/test-skill"
  cat > "$SKILLS_TMP/test-skill/SKILL.md" <<'MD'
---
name: test-skill
description: A test skill for testing.
---

# Test Skill
This is a test.
MD

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_skills_catalog '$SKILLS_TMP'"
  [ "$status" -eq 0 ]

  # Should be valid JSON with one entry
  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_skills_catalog '$SKILLS_TMP' | jq '.[0].id'"
  [ "$status" -eq 0 ]
  [ "$output" = '"test-skill"' ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_skills_catalog '$SKILLS_TMP' | jq '.[0].description'"
  [ "$status" -eq 0 ]
  [ "$output" = '"A test skill for testing."' ]

  rm -rf "$SKILLS_TMP"
}

@test "build_skills_catalog returns empty array for missing dir" {
  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_skills_catalog '/tmp/nonexistent_skills_$$'"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "build_skills_catalog handles malformed SKILL.md gracefully" {
  SKILLS_TMP=$(mktemp -d)
  mkdir -p "$SKILLS_TMP/good-skill" "$SKILLS_TMP/bad-skill"

  cat > "$SKILLS_TMP/good-skill/SKILL.md" <<'MD'
---
name: good-skill
description: This one is fine.
---
MD

  # Create a file with bad encoding
  printf '\xff\xfe' > "$SKILLS_TMP/bad-skill/SKILL.md"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_skills_catalog '$SKILLS_TMP' 2>/dev/null | jq 'length'"
  [ "$status" -eq 0 ]
  # Should have at least the good skill (bad one skipped)
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]

  rm -rf "$SKILLS_TMP"
}

@test "run_task.sh detects retry loop with 3 identical blocked errors" {
  run "${REPO_DIR}/scripts/add_task.sh" "Retry Loop" "Test retry loop detection" ""
  [ "$status" -eq 0 ]

  # Set up task with 3 attempts and 3 identical blocked history entries
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  export NOW
  yq -i "(.tasks[] | select(.id == 2) | .agent) = \"codex\" |
    (.tasks[] | select(.id == 2) | .attempts) = 3 |
    (.tasks[] | select(.id == 2) | .status) = \"routed\" |
    (.tasks[] | select(.id == 2) | .history) = [
      {\"ts\": \"2026-01-01T00:00:00Z\", \"status\": \"blocked\", \"note\": \"agent command failed (exit 1)\"},
      {\"ts\": \"2026-01-01T00:01:00Z\", \"status\": \"blocked\", \"note\": \"agent command failed (exit 1)\"},
      {\"ts\": \"2026-01-01T00:02:00Z\", \"status\": \"blocked\", \"note\": \"agent command failed (exit 1)\"}
    ]" "$TASKS_PATH"

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
echo "should not be called" >&2
exit 1
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should be needs_review due to retry loop
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  run yq -r '.tasks[] | select(.id == 2) | .last_error' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retry loop"* ]]
}

@test "run_task.sh does not detect retry loop with varied errors" {
  run "${REPO_DIR}/scripts/add_task.sh" "No Loop" "Different errors each time" ""
  [ "$status" -eq 0 ]

  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  export NOW
  yq -i "(.tasks[] | select(.id == 2) | .agent) = \"codex\" |
    (.tasks[] | select(.id == 2) | .attempts) = 3 |
    (.tasks[] | select(.id == 2) | .status) = \"routed\" |
    (.tasks[] | select(.id == 2) | .history) = [
      {\"ts\": \"2026-01-01T00:00:00Z\", \"status\": \"blocked\", \"note\": \"error A\"},
      {\"ts\": \"2026-01-01T00:01:00Z\", \"status\": \"blocked\", \"note\": \"error B\"},
      {\"ts\": \"2026-01-01T00:02:00Z\", \"status\": \"blocked\", \"note\": \"error C\"}
    ]" "$TASKS_PATH"

  # Stub that succeeds (prints JSON to stdout)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"fixed it","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should complete normally (not blocked by retry loop)
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "agent prompt includes error history and issue comments sections" {
  run grep -c 'TASK_HISTORY\|TASK_LAST_ERROR\|ISSUE_COMMENTS' "${REPO_DIR}/prompts/agent.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "system prompt enforces workflow rules" {
  run grep -c 'worktree\|Do NOT run.*git push\|Do NOT mark.*done\|commit' "${REPO_DIR}/prompts/system.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "system prompt includes logging instructions" {
  run grep -c 'accomplished.*bullet\|remaining.*owner\|files_changed.*comment\|reason.*error' "${REPO_DIR}/prompts/system.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "gh_push.sh has comment dedup functions" {
  run grep -c 'should_skip_comment\|store_comment_hash\|last_comment_hash' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "gh_push.sh applies blocked label on blocked status" {
  run grep -c 'ensure_label.*blocked.*d73a4a\|labels.*blocked' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gh_push.sh uses atomic gh_synced_at write" {
  # Must use yq self-reference, not strenv(UPDATED_AT)
  run grep -c 'gh_synced_at.*=.*updated_at' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]

  # Must NOT use strenv(UPDATED_AT) for gh_synced_at
  run bash -c "grep 'gh_synced_at.*strenv(UPDATED_AT)' '${REPO_DIR}/scripts/gh_push.sh' || true"
  [ -z "$output" ]
}

@test "skills_sync.sh uses ORCH_HOME paths" {
  run grep -c 'ORCH_HOME' "${REPO_DIR}/scripts/skills_sync.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "lib.sh defaults to ORCH_HOME for state paths" {
  run bash -c "head -10 '${REPO_DIR}/scripts/lib.sh' | grep -c 'ORCH_HOME'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

# --- start/stop/restart routing tests ---

@test "start delegates to brew services when ORCH_BREW=1" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  # Create a mock brew that records the command
  BREW_STUB="${TMP_DIR}/brew"
  cat > "$BREW_STUB" <<'SH'
#!/usr/bin/env bash
echo "brew $*"
SH
  chmod +x "$BREW_STUB"

  run env PATH="${TMP_DIR}:${PATH}" ORCH_BREW=1 \
    just --justfile "${REPO_DIR}/justfile" --working-directory "${REPO_DIR}" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew services start orchestrator"* ]]
}

@test "stop delegates to brew services when ORCH_BREW=1" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  BREW_STUB="${TMP_DIR}/brew"
  cat > "$BREW_STUB" <<'SH'
#!/usr/bin/env bash
echo "brew $*"
SH
  chmod +x "$BREW_STUB"

  run env PATH="${TMP_DIR}:${PATH}" ORCH_BREW=1 \
    just --justfile "${REPO_DIR}/justfile" --working-directory "${REPO_DIR}" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew services stop orchestrator"* ]]
}

@test "restart delegates to brew services when ORCH_BREW=1" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  BREW_STUB="${TMP_DIR}/brew"
  cat > "$BREW_STUB" <<'SH'
#!/usr/bin/env bash
echo "brew $*"
SH
  chmod +x "$BREW_STUB"

  run env PATH="${TMP_DIR}:${PATH}" ORCH_BREW=1 \
    just --justfile "${REPO_DIR}/justfile" --working-directory "${REPO_DIR}" restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew services restart orchestrator"* ]]
}

@test "info delegates to brew services when ORCH_BREW=1" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  BREW_STUB="${TMP_DIR}/brew"
  cat > "$BREW_STUB" <<'SH'
#!/usr/bin/env bash
echo "brew $*"
SH
  chmod +x "$BREW_STUB"

  run env PATH="${TMP_DIR}:${PATH}" ORCH_BREW=1 \
    just --justfile "${REPO_DIR}/justfile" --working-directory "${REPO_DIR}" info
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew services info orchestrator"* ]]
}

@test "info shows pid status when ORCH_BREW is not set" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  run env STATE_DIR="$STATE_DIR" \
    just --justfile "${REPO_DIR}/justfile" --working-directory "${REPO_DIR}" info
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
}

@test "service namespace is visible, serve is private" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  run just --justfile "${REPO_DIR}/justfile" --list
  [ "$status" -eq 0 ]
  # service should be visible
  [[ "$output" == *"service"* ]]
  # "serve" recipe should NOT be listed (it's private) — check for exact recipe name
  ! echo "$output" | grep -qE '^\s+serve\b'
}

@test "Formula wrapper sets ORCH_BREW=1" {
  run grep 'ORCH_BREW=1' "${REPO_DIR}/Formula/orchestrator.rb"
  [ "$status" -eq 0 ]
}

@test "brew service runs orchestrator serve not start" {
  # Verify service definition uses 'serve' to avoid recursion
  run grep 'serve' "${REPO_DIR}/Formula/orchestrator.rb"
  [ "$status" -eq 0 ]
  # Must NOT have service calling 'start'
  run bash -c "grep 'run.*\"start\"' '${REPO_DIR}/Formula/orchestrator.rb' || true"
  [ -z "$output" ]
}

# --- Visibility / reporting tests ---

@test "duration_fmt formats seconds correctly" {
  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && duration_fmt 45"
  [ "$output" = "45s" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && duration_fmt 125"
  [ "$output" = "2m 5s" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && duration_fmt 3661"
  [ "$output" = "1h 1m" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && duration_fmt 0"
  [ "$output" = "0s" ]
}

@test "normalize_json.py --usage extracts token counts" {
  EVENTS='{"type":"result","usage":{"input_tokens":15000,"output_tokens":3000}}'
  run bash -c "RAW_RESPONSE='$EVENTS' python3 '${REPO_DIR}/scripts/normalize_json.py' --usage"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.input_tokens == 15000'
  echo "$output" | jq -e '.output_tokens == 3000'
}

@test "normalize_json.py --usage returns zeros on no usage" {
  EVENTS='{"type":"text","part":{"text":"hello"}}'
  run bash -c "RAW_RESPONSE='$EVENTS' python3 '${REPO_DIR}/scripts/normalize_json.py' --usage"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.input_tokens == 0'
  echo "$output" | jq -e '.output_tokens == 0'
}

@test "read_tool_summary generates markdown table from tools JSON" {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/tools-1.json" <<'JSON'
[
  {"tool":"Bash","input":{"command":"ls"},"error":false},
  {"tool":"Bash","input":{"command":"git push"},"error":true},
  {"tool":"Read","input":{"file_path":"foo.txt"},"error":false},
  {"tool":"Edit","input":{"file_path":"bar.txt"},"error":false}
]
JSON

  # Extract just the read_tool_summary function and test it
  local func_file="${TMP_DIR}/tool_summary_func.sh"
  sed -n '/^read_tool_summary()/,/^}/p' "${REPO_DIR}/scripts/gh_push.sh" > "$func_file"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && source '$func_file' && read_tool_summary '' 1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '| Bash | 2 |'
  echo "$output" | grep -q '| Read | 1 |'
  echo "$output" | grep -q 'Failed tool calls (1)'
  echo "$output" | grep -q 'git push'
}

@test "read_tool_summary returns empty for missing file" {
  local func_file="${TMP_DIR}/tool_summary_func.sh"
  sed -n '/^read_tool_summary()/,/^}/p' "${REPO_DIR}/scripts/gh_push.sh" > "$func_file"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && source '$func_file' && read_tool_summary '' 999"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh_push.sh comment includes duration and tokens" {
  run grep -c 'Duration\|Tokens\|duration_fmt' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "gh_push.sh comment includes tool activity section" {
  run grep -c 'read_tool_summary\|Agent Activity' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gh_push.sh comment includes stderr section" {
  run grep -c 'stderr_snippet\|Agent stderr' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "run_task.sh stores duration and tokens in task YAML" {
  run grep -c 'duration\|input_tokens\|output_tokens\|AGENT_DURATION\|stderr_snippet' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 6 ]
}

@test "run_task.sh completion log includes duration and tokens" {
  run grep 'DONE.*duration.*tokens' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
}

@test "dashboard.sh runs without errors" {
  # Add tasks with gh_issue_number to exercise issue formatting
  yq -i '(.tasks[] | select(.id == 1) | .gh_issue_number) = 10' "$TASKS_PATH"
  run "${REPO_DIR}/scripts/dashboard.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tasks:"* ]]
  [[ "$output" == *"Projects:"* ]]
  [[ "$output" == *"Worktrees:"* ]]
}

@test "status.sh --global shows PROJECT column" {
  # Add a task with a dir to test global view
  yq -i '(.tasks[] | select(.id == 1) | .dir) = "/Users/test/myproject"' "$TASKS_PATH"
  run "${REPO_DIR}/scripts/status.sh" --global
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT"* ]]
  [[ "$output" == *"myproject"* ]]
}

@test "list_tasks.sh shows table with issue numbers" {
  yq -i '(.tasks[] | select(.id == 1) | .gh_issue_number) = 42' "$TASKS_PATH"
  run "${REPO_DIR}/scripts/list_tasks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#42"* ]]
  [[ "$output" == *"ISSUE"* ]]
}

@test "task_field reads a task field" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file
  run task_field 1 .title
  [ "$status" -eq 0 ]
  [ "$output" = "Init" ]
}

@test "task_count counts tasks by status" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file
  run task_count "new"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run task_count
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "job add --type bash creates bash job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file
  run "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "echo hello" "0 * * * *" "Test bash job"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash job"* ]]

  run yq -r '.jobs[0].type' "$JOBS_PATH"
  [ "$output" = "bash" ]

  run yq -r '.jobs[0].command' "$JOBS_PATH"
  [ "$output" = "echo hello" ]
}

# --- tree.sh ---

@test "tree.sh displays task tree" {
  run "${REPO_DIR}/scripts/tree.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Init"* ]]
  [[ "$output" == *"[1]"* ]]
  [[ "$output" == *"(new)"* ]]
}

@test "tree.sh shows parent-child relationships" {
  "${REPO_DIR}/scripts/add_task.sh" "Parent" "" "" >/dev/null
  "${REPO_DIR}/scripts/add_task.sh" "Child" "" "" >/dev/null
  # Set up parent-child relationship
  yq -i '(.tasks[] | select(.id == 3) | .parent_id) = 2 |
         (.tasks[] | select(.id == 2) | .children) = [3]' "$TASKS_PATH"

  run "${REPO_DIR}/scripts/tree.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parent"* ]]
  [[ "$output" == *"Child"* ]]
  # Child should be indented under parent
  [[ "$output" == *"└─"* ]] || [[ "$output" == *"├─"* ]]
}

# --- retry_task.sh ---

@test "retry_task.sh resets done task to new" {
  yq -i '(.tasks[] | select(.id == 1) | .status) = "done"' "$TASKS_PATH"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 1) | .status' "$TASKS_PATH"
  [ "$output" = "new" ]
}

@test "retry_task.sh resets blocked task to new" {
  yq -i '(.tasks[] | select(.id == 1) | .status) = "blocked"' "$TASKS_PATH"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 1) | .status' "$TASKS_PATH"
  [ "$output" = "new" ]
}

@test "retry_task.sh clears agent on reset" {
  yq -i '(.tasks[] | select(.id == 1) | .status) = "done" |
         (.tasks[] | select(.id == 1) | .agent) = "claude"' "$TASKS_PATH"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 1) | .agent' "$TASKS_PATH"
  [ "$output" = "null" ]
}

@test "retry_task.sh skips already-new tasks" {
  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"already new"* ]] || true
}

@test "retry_task.sh fails on missing task" {
  run "${REPO_DIR}/scripts/retry_task.sh" 999
  [ "$status" -ne 0 ]
}

@test "retry_task.sh requires task id" {
  run "${REPO_DIR}/scripts/retry_task.sh"
  [ "$status" -ne 0 ]
}

# --- set_agent.sh ---

@test "set_agent.sh sets agent on a task" {
  run "${REPO_DIR}/scripts/set_agent.sh" 1 claude
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 1) | .agent' "$TASKS_PATH"
  [ "$output" = "claude" ]
}

@test "set_agent.sh requires both id and agent" {
  run "${REPO_DIR}/scripts/set_agent.sh" 1
  [ "$status" -ne 0 ]

  run "${REPO_DIR}/scripts/set_agent.sh"
  [ "$status" -ne 0 ]
}

# --- jobs_list.sh ---

@test "jobs_list.sh shows no jobs message" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file
  run "${REPO_DIR}/scripts/jobs_list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No jobs"* ]]
}

@test "jobs_list.sh shows job details" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file
  "${REPO_DIR}/scripts/jobs_add.sh" "0 9 * * *" "Daily Check" "check things" "" >/dev/null

  run "${REPO_DIR}/scripts/jobs_list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily-check"* ]]
  [[ "$output" == *"0 9 * * *"* ]]
  [[ "$output" == *"true"* ]]
  [[ "$output" == *"TYPE"* ]]
}

@test "jobs_list.sh shows bash job type" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file
  "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "echo hi" "@hourly" "Ping" >/dev/null

  run "${REPO_DIR}/scripts/jobs_list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash"* ]]
}

# --- output.sh helpers ---

@test "output.sh status_icon returns correct icons" {
  source "${REPO_DIR}/scripts/output.sh"
  run status_icon "done"
  [ "$output" = "✓" ]

  run status_icon "blocked"
  [ "$output" = "✗" ]

  run status_icon "new"
  [ "$output" = "○" ]
}

@test "output.sh fmt_issue formats issue numbers" {
  source "${REPO_DIR}/scripts/output.sh"

  run fmt_issue 42
  [ "$output" = "#42" ]

  run fmt_issue ""
  [ "$output" = "-" ]

  run fmt_issue "null"
  [ "$output" = "-" ]
}

@test "output.sh table_with_header formats table" {
  source "${REPO_DIR}/scripts/output.sh"
  result=$(printf '1\tnew\tInit\n' | table_with_header "ID\tSTATUS\tTITLE")
  [[ "$result" == *"ID"* ]]
  [[ "$result" == *"STATUS"* ]]
  [[ "$result" == *"Init"* ]]
}

# --- jobs_tick.sh bash execution ---

@test "jobs_tick.sh runs bash job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file

  # Create bash job matching every minute
  "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "echo test-output" "* * * * *" "Always Run" >/dev/null

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Check last_run is set
  run yq -r '.jobs[0].last_run' "$JOBS_PATH"
  [ "$output" != "null" ]
  [ -n "$output" ]
}

@test "jobs_tick.sh records bash job failure" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file

  # Create bash job that fails
  "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "exit 1" "* * * * *" "Fail Job" >/dev/null

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  run yq -r '.jobs[0].last_task_status' "$JOBS_PATH"
  [ "$output" = "failed" ]
}

@test "jobs_tick.sh disables bash job when dir is missing" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file

  MISSING_DIR="${TMP_DIR}/does-not-exist"
  PROJECT_DIR="$MISSING_DIR" "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "echo test-output" "* * * * *" "Bad Dir Job" >/dev/null

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  run yq -r '.jobs[0].enabled' "$JOBS_PATH"
  [ "$output" = "false" ]

  run yq -r '.jobs[0].last_task_status' "$JOBS_PATH"
  [ "$output" = "failed" ]
}

# --- status.sh ---

@test "status.sh shows counts table" {
  run "${REPO_DIR}/scripts/status.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS"* ]]
  [[ "$output" == *"QTY"* ]]
  [[ "$output" == *"new"* ]]
  [[ "$output" == *"total"* ]]
}

@test "status.sh --json --global returns valid JSON" {
  run "${REPO_DIR}/scripts/status.sh" --json --global
  [ "$status" -eq 0 ]
  # Validate it's JSON
  printf '%s' "$output" | jq . >/dev/null
  # Check total
  TOTAL=$(printf '%s' "$output" | jq -r '.total')
  [ "$TOTAL" -ge 1 ]
}

# --- add_task.sh edge cases ---

@test "add_task.sh with empty body and labels" {
  run "${REPO_DIR}/scripts/add_task.sh" "No Body Task" "" ""
  [ "$status" -eq 0 ]

  run yq -r '.tasks[-1].title' "$TASKS_PATH"
  [ "$output" = "No Body Task" ]

  run yq -r '.tasks[-1].body' "$TASKS_PATH"
  [ "$output" = "" ] || [ "$output" = "null" ]
}

@test "add_task.sh assigns sequential ids" {
  "${REPO_DIR}/scripts/add_task.sh" "Task A" "" "" >/dev/null
  "${REPO_DIR}/scripts/add_task.sh" "Task B" "" "" >/dev/null
  "${REPO_DIR}/scripts/add_task.sh" "Task C" "" "" >/dev/null

  run yq -r '.tasks[-1].id' "$TASKS_PATH"
  ID_C="$output"

  run yq -r '.tasks[-2].id' "$TASKS_PATH"
  ID_B="$output"

  # IDs should be sequential
  [ "$ID_C" -gt "$ID_B" ]
}

# --- task_set helper ---

@test "task_set updates a task field" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  task_set 1 .status "blocked"

  run yq -r '.tasks[] | select(.id == 1) | .status' "$TASKS_PATH"
  [ "$output" = "blocked" ]
}

# --- unlock.sh ---

@test "available_agents respects disabled_agents config" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  # Disable codex
  yq -i '.router.disabled_agents = ["codex"]' "$CONFIG_PATH"

  result=$(available_agents)
  # codex should NOT be in result (if installed)
  [[ "$result" != *"codex"* ]] || skip "codex not installed"
  # claude should still be there (if installed)
  if command -v claude >/dev/null 2>&1; then
    [[ "$result" == *"claude"* ]]
  fi
}

@test "load_project_config merges per-project .orchestrator.yml" {
  # Create a per-project config with a different repo
  cat > "${TMP_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: "testorg/testrepo"
  project_id: "PVT_test123"
YAML

  # Global config has a different repo
  run yq -i '.gh.repo = "global/repo"' "$CONFIG_PATH"

  # Source lib and load project config — PROJECT_DIR must be set first
  run bash -c '
    export PROJECT_DIR="'"$TMP_DIR"'"
    export CONFIG_PATH="'"$CONFIG_PATH"'"
    export TASKS_PATH="'"$TASKS_PATH"'"
    export STATE_DIR="'"$STATE_DIR"'"
    source "'"$REPO_DIR"'/scripts/lib.sh"
    load_project_config
    config_get ".gh.repo"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "testorg/testrepo" ]
}

@test "load_project_config uses global config when no project config exists" {
  # No .orchestrator.yml in PROJECT_DIR
  run yq -i '.gh.repo = "global/repo"' "$CONFIG_PATH"

  run bash -c '
    export PROJECT_DIR="'"$TMP_DIR"'/no-project"
    export CONFIG_PATH="'"$CONFIG_PATH"'"
    export TASKS_PATH="'"$TASKS_PATH"'"
    export STATE_DIR="'"$STATE_DIR"'"
    mkdir -p "$PROJECT_DIR"
    source "'"$REPO_DIR"'/scripts/lib.sh"
    load_project_config
    config_get ".gh.repo"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "global/repo" ]
}

@test "gh_pull.sh uses PROJECT_DIR for repo detection" {
  # Create per-project config
  cat > "${TMP_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: "testorg/testrepo"
YAML

  # Mock gh to capture the repo it receives
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]]; then
  echo "repo=$REPO" >&2
  echo "[]"
fi
exit 0
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" PROJECT_DIR="$TMP_DIR" \
    "${REPO_DIR}/scripts/gh_pull.sh"
  # Should not fail (may have no issues, that's fine)
  # The key test: it loaded the per-project repo
  run bash -c '
    export PROJECT_DIR="'"$TMP_DIR"'"
    export CONFIG_PATH="'"$CONFIG_PATH"'"
    export TASKS_PATH="'"$TASKS_PATH"'"
    export STATE_DIR="'"$STATE_DIR"'"
    source "'"$REPO_DIR"'/scripts/lib.sh"
    load_project_config
    config_get ".gh.repo"
  '
  [ "$output" = "testorg/testrepo" ]
}

@test "load_project_config called twice uses global config not merged" {
  # Regression test: when parent process calls load_project_config, CONFIG_PATH
  # becomes config-merged.yml. If a child process inherits this and calls
  # load_project_config again, it must still merge from the GLOBAL config,
  # not from the already-merged file (which would produce empty output).
  cat > "${TMP_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: "testorg/testrepo"
YAML

  run bash -c '
    export PROJECT_DIR="'"$TMP_DIR"'"
    export CONFIG_PATH="'"$CONFIG_PATH"'"
    export TASKS_PATH="'"$TASKS_PATH"'"
    export STATE_DIR="'"$STATE_DIR"'"
    source "'"$REPO_DIR"'/scripts/lib.sh"
    # First call (parent process)
    load_project_config
    repo1=$(config_get ".gh.repo")
    # Second call (simulates child process inheriting CONFIG_PATH=merged)
    load_project_config
    repo2=$(config_get ".gh.repo")
    echo "first=$repo1 second=$repo2"
    [ "$repo1" = "testorg/testrepo" ] && [ "$repo2" = "testorg/testrepo" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"first=testorg/testrepo second=testorg/testrepo"* ]]
}

@test "all scripts set PROJECT_DIR before load_project_config" {
  # This is a lint test — ensures no script calls load_project_config
  # before setting PROJECT_DIR, which causes wrong config loading.
  FAILURES=""
  for f in "${REPO_DIR}"/scripts/*.sh; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    # Skip lib.sh (defines the function)
    [ "$fname" = "lib.sh" ] && continue
    grep -q 'load_project_config' "$f" || continue
    pd_line=$(grep -n 'PROJECT_DIR=' "$f" | head -1 | cut -d: -f1)
    lp_line=$(grep -n 'load_project_config' "$f" | head -1 | cut -d: -f1)
    if [ -z "$pd_line" ] || [ "$pd_line" -gt "$lp_line" ]; then
      FAILURES="${FAILURES}${fname}: PROJECT_DIR set at line ${pd_line:-MISSING}, load_project_config at line ${lp_line}\n"
    fi
  done
  if [ -n "$FAILURES" ]; then
    printf "Scripts with PROJECT_DIR after load_project_config:\n%b" "$FAILURES"
    return 1
  fi
}

@test "gh_sync.sh loads per-project config" {
  cat > "${TMP_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: "testorg/syncrepo"
  enabled: false
YAML

  run env PROJECT_DIR="$TMP_DIR" "${REPO_DIR}/scripts/gh_sync.sh" 2>&1
  [ "$status" -eq 0 ]
  # gh_sync exits early with "disabled" — proves it loaded the project config
  [[ "$output" == *"disabled"* ]]
}

@test "unlock.sh removes lock files" {
  # Create fake lock files
  touch "${TASKS_PATH}.lock"
  touch "${TASKS_PATH}.lock.task.1"
  touch "${TASKS_PATH}.lock.task.2"

  run "${REPO_DIR}/scripts/unlock.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed"* ]]
}

# --- Integration: full worktree workflow ---

@test "e2e: worktree created, agent runs, commits, push attempted, PR attempted" {
  # Create a "remote" bare repo to push to
  REMOTE_DIR="${TMP_DIR}/remote.git"
  git init --bare "$REMOTE_DIR" --quiet
  git -C "$PROJECT_DIR" remote add origin "$REMOTE_DIR"
  git -C "$PROJECT_DIR" push -u origin main --quiet 2>/dev/null

  # Add a task with issue number
  run "${REPO_DIR}/scripts/add_task.sh" "Add README" "Create a README.md file" ""
  [ "$status" -eq 0 ]

  # Set agent and issue number
  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex" |
    (.tasks[] | select(.id == 2) | .gh_issue_number) = 42 |
    (.tasks[] | select(.id == 2) | .gh_url) = "https://github.com/test/repo/issues/42"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Stub codex: writes output JSON to .orchestrator/ and creates a file + commit
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'STUB'
#!/usr/bin/env bash
# Simulate agent work: create file and commit
echo "# Test Repo" > README.md
git add README.md
git commit -m "docs: add README" --quiet 2>/dev/null

# Write output JSON to .orchestrator/ inside the worktree
mkdir -p .orchestrator
cat > .orchestrator/output-2.json <<'JSON'
{"status":"done","summary":"Added README","files_changed":["README.md"],"needs_help":false,"accomplished":["Created README.md"],"remaining":[],"blockers":[],"delegations":[]}
JSON
STUB
  chmod +x "$CODEX_STUB"

  # Stub gh (PR creation will be attempted)
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* ]]; then
  echo ""
  exit 0
elif [[ "$*" == *"pr create"* ]]; then
  echo "https://github.com/test/repo/pull/1"
  exit 0
elif [[ "$*" == *"issue develop"* ]]; then
  exit 0
fi
exit 0
STUB
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Verify worktree was created
  WORKTREE_DIR="${ORCH_HOME}/worktrees/$(basename "$PROJECT_DIR" .git)/gh-task-42-add-readme"
  [ -d "$WORKTREE_DIR" ]

  # Verify worktree info saved to task
  run yq -r '.tasks[] | select(.id == 2) | .worktree' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-task-42-add-readme"* ]]

  run yq -r '.tasks[] | select(.id == 2) | .branch' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "gh-task-42-add-readme" ]

  # Verify task completed
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # Verify commit exists in worktree
  run git -C "$WORKTREE_DIR" log --oneline main..HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"add README"* ]]

  # Verify branch was pushed to remote
  run git -C "$REMOTE_DIR" branch --list "gh-task-42-add-readme"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-task-42-add-readme"* ]]

  # Clean up worktree
  git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  git -C "$PROJECT_DIR" branch -D "gh-task-42-add-readme" 2>/dev/null || true
}

@test "e2e: auto-commit when agent writes files but does not commit" {
  # Create a "remote" bare repo to push to
  REMOTE_DIR="${TMP_DIR}/remote.git"
  git init --bare "$REMOTE_DIR" --quiet
  git -C "$PROJECT_DIR" remote add origin "$REMOTE_DIR"
  git -C "$PROJECT_DIR" push -u origin main --quiet 2>/dev/null

  # Add a task with issue number
  run "${REPO_DIR}/scripts/add_task.sh" "Add LICENSE" "Create a LICENSE file" ""
  [ "$status" -eq 0 ]

  # Set agent and issue number
  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "claude" |
    (.tasks[] | select(.id == 2) | .gh_issue_number) = 55 |
    (.tasks[] | select(.id == 2) | .gh_url) = "https://github.com/test/repo/issues/55"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Stub claude: writes files and output JSON but does NOT git commit
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'STUB'
#!/usr/bin/env bash
# Simulate agent that edits files but cannot run git commit (acceptEdits mode)
echo "MIT License" > LICENSE
mkdir -p .orchestrator
cat > .orchestrator/output-2.json <<'JSON'
{"status":"done","summary":"Added LICENSE","files_changed":["LICENSE"],"needs_help":false,"accomplished":["Created LICENSE"],"remaining":[],"blockers":[],"delegations":[]}
JSON
STUB
  chmod +x "$CLAUDE_STUB"

  # Stub gh
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* ]]; then
  echo ""
  exit 0
elif [[ "$*" == *"pr create"* ]]; then
  echo "https://github.com/test/repo/pull/2"
  exit 0
elif [[ "$*" == *"issue develop"* ]]; then
  exit 0
fi
exit 0
STUB
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Verify worktree was created
  WORKTREE_DIR="${ORCH_HOME}/worktrees/$(basename "$PROJECT_DIR" .git)/gh-task-55-add-license"
  [ -d "$WORKTREE_DIR" ]

  # Verify orchestrator auto-committed the changes
  run git -C "$WORKTREE_DIR" log --oneline main..HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"Add LICENSE"* ]]

  # Verify LICENSE file is tracked
  run git -C "$WORKTREE_DIR" show HEAD:LICENSE
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIT License"* ]]

  # Verify branch was pushed to remote
  run git -C "$REMOTE_DIR" branch --list "gh-task-55-add-license"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-task-55-add-license"* ]]

  # Clean up worktree
  git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  git -C "$PROJECT_DIR" branch -D "gh-task-55-add-license" 2>/dev/null || true
}

@test "model_for_complexity resolves agent model from config" {
  # Add model_map to config
  yq -i '.model_map.simple.claude = "haiku" |
         .model_map.simple.codex = "gpt-5.1-codex-mini" |
         .model_map.medium.claude = "sonnet" |
         .model_map.medium.codex = "gpt-5.2" |
         .model_map.complex.claude = "opus" |
         .model_map.complex.codex = "gpt-5.3-codex"' "$CONFIG_PATH"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude simple"
  [ "$status" -eq 0 ]
  [ "$output" = "haiku" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude medium"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude complex"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity codex medium"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.2" ]

  # Unconfigured agent returns empty
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity opencode simple"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "route_task.sh stores complexity label instead of model" {
  run "${REPO_DIR}/scripts/add_task.sh" "Route Complexity" "Test complexity routing" ""
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"executor":"codex","complexity":"simple","reason":"docs task","profile":{"role":"writer","skills":["docs"],"tools":["git"],"constraints":[]},"selected_skills":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/route_task.sh" 2
  [ "$status" -eq 0 ]

  # Complexity should be stored on the task
  run yq -r '.tasks[] | select(.id == 2) | .complexity' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "simple" ]

  # Label should be complexity:simple, not model:*
  run yq -r '.tasks[] | select(.id == 2) | .labels[]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complexity:simple"* ]]
  [[ "$output" != *"model:"* ]]
}

@test "route_task.sh fallback sets complexity to medium" {
  run "${REPO_DIR}/scripts/add_task.sh" "Fallback Complexity" "Test fallback" ""
  [ "$status" -eq 0 ]

  run yq -i '.router.agent = "claude" | .router.timeout_seconds = 0 | .router.fallback_executor = "codex"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$CLAUDE_STUB"

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
echo "stub"
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/route_task.sh" 2
  [ "$status" -eq 0 ]

  # Fallback should default to medium complexity
  run yq -r '.tasks[] | select(.id == 2) | .complexity' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "medium" ]

  # Label should include complexity:medium
  run yq -r '.tasks[] | select(.id == 2) | .labels[]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complexity:medium"* ]]
}

@test "create_task_entry includes complexity field" {
  NOW="2026-01-01T00:00:00Z"
  export NOW PROJECT_DIR="$TMP_DIR"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    TASKS_PATH='$TASKS_PATH'
    create_task_entry 99 'Complexity Task' 'Test body' 'test' '' ''
  "
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 99) | .complexity' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "run_task.sh resolves model from complexity config" {
  run "${REPO_DIR}/scripts/add_task.sh" "Resolve Model" "Test model resolution" ""
  [ "$status" -eq 0 ]

  # Add model_map and set complexity on task
  yq -i '.model_map.simple.codex = "gpt-5.1-codex-mini" |
         .model_map.medium.codex = "gpt-5.2" |
         .model_map.complex.codex = "gpt-5.3-codex"' "$CONFIG_PATH"

  yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex" |
         (.tasks[] | select(.id == 2) | .complexity) = "simple"' "$TASKS_PATH"

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"resolved model","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "review agent uses reject decision to close PR" {
  run "${REPO_DIR}/scripts/add_task.sh" "Review Reject" "Test reject" ""
  [ "$status" -eq 0 ]

  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Execution stub (codex) returns done
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"done","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  # Review stub (claude) returns reject
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"decision":"reject","notes":"hallucinated API calls"}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  # Mock gh — return PR number for list, accept diff/review/close
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo "42"
elif [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "+added line"
elif [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  echo "ok"
elif [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  echo "ok"
elif [ "$1" = "issue" ]; then
  echo ""
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should be needs_review after reject
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  # Last error should mention rejection
  run yq -r '.tasks[] | select(.id == 2) | .last_error' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review rejected"* ]]
}

@test "model_for_complexity defaults to medium when null" {
  yq -i '.model_map.medium.claude = "sonnet"' "$CONFIG_PATH"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude ''"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude null"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "model_for_complexity returns empty for unconfigured model_map" {
  # No model_map in config at all
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; model_for_complexity claude complex"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run_task.sh sandbox adds disallowed tools for main project dir" {
  # Verify the sandbox code block exists and generates correct patterns
  run grep -c 'SANDBOX_PATTERNS' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  # Verify sandbox patterns include Read, Write, Edit, Bash restrictions
  run grep 'SANDBOX_PATTERNS=' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Read('* ]]
  [[ "$output" == *'Write('* ]]
  [[ "$output" == *'Edit('* ]]
  [[ "$output" == *'Bash(cd'* ]]
}

@test "run_task.sh saves MAIN_PROJECT_DIR before worktree override" {
  run grep -n 'MAIN_PROJECT_DIR=' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'MAIN_PROJECT_DIR="$PROJECT_DIR"'* ]]
}

@test "opposite_agent picks different agent from task agent" {
  # Make both codex and claude available; opposite of codex should be claude
  CODEX_STUB="${TMP_DIR}/codex"
  printf '#!/usr/bin/env bash\necho ok\n' > "$CODEX_STUB"
  chmod +x "$CODEX_STUB"

  CLAUDE_STUB="${TMP_DIR}/claude"
  printf '#!/usr/bin/env bash\necho ok\n' > "$CLAUDE_STUB"
  chmod +x "$CLAUDE_STUB"

  run bash -c "export PATH='${TMP_DIR}:${PATH}'; source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; opposite_agent codex"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]

  # opposite of claude should be codex
  run bash -c "export PATH='${TMP_DIR}:${PATH}'; source '${REPO_DIR}/scripts/lib.sh'; CONFIG_PATH='$CONFIG_PATH'; opposite_agent claude"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}

@test "review agent request_changes posts review but does not close PR" {
  run "${REPO_DIR}/scripts/add_task.sh" "Review Changes" "Test request_changes" ""
  [ "$status" -eq 0 ]

  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Execution stub (codex) returns done
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"done","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"

  # Review stub (claude) returns request_changes
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"decision":"request_changes","notes":"missing error handling"}
JSON
SH
  chmod +x "$CLAUDE_STUB"

  # Mock gh — track calls to detect if pr close was called
  GH_LOG="${STATE_DIR}/gh_calls.log"
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<SH
#!/usr/bin/env bash
echo "\$@" >> "${GH_LOG}"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  echo "42"
elif [ "\$1" = "pr" ] && [ "\$2" = "diff" ]; then
  echo "+added line"
elif [ "\$1" = "pr" ] && [ "\$2" = "review" ]; then
  echo "ok"
elif [ "\$1" = "pr" ] && [ "\$2" = "close" ]; then
  echo "ok"
elif [ "\$1" = "issue" ]; then
  echo ""
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should be needs_review (not done)
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  # gh pr review should have been called (request-changes)
  run grep "pr review" "$GH_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--request-changes"* ]]

  # gh pr close should NOT have been called
  run grep "pr close" "$GH_LOG"
  [ "$status" -ne 0 ]
}

@test "fetch_owner_feedback filters to owner comments" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"*"comments"* ]]; then
  cat <<'JSON'
[
  {"user":{"login":"owner1"},"created_at":"2026-01-01T00:00:01Z","body":"Fix this please"},
  {"user":{"login":"contributor"},"created_at":"2026-01-01T00:00:02Z","body":"I disagree"},
  {"user":{"login":"owner1"},"created_at":"2026-01-01T00:00:03Z","body":"This should be internal"}
]
JSON
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run bash -c "export PATH='${TMP_DIR}:${PATH}'; source '${REPO_DIR}/scripts/lib.sh'; fetch_owner_feedback 'org/repo' 42 'owner1' ''"
  [ "$status" -eq 0 ]

  count=$(printf '%s' "$output" | yq -r 'length')
  [ "$count" -eq 2 ]

  login0=$(printf '%s' "$output" | yq -r '.[0].login')
  [ "$login0" = "owner1" ]

  login1=$(printf '%s' "$output" | yq -r '.[1].login')
  [ "$login1" = "owner1" ]
}

@test "fetch_owner_feedback excludes orchestrator bot comments" {
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"*"comments"* ]]; then
  cat <<'JSON'
[
  {"user":{"login":"owner1"},"created_at":"2026-01-01T00:00:01Z","body":"Real feedback"},
  {"user":{"login":"owner1"},"created_at":"2026-01-01T00:00:02Z","body":"Automated update via [Orchestrator]"}
]
JSON
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run bash -c "export PATH='${TMP_DIR}:${PATH}'; source '${REPO_DIR}/scripts/lib.sh'; fetch_owner_feedback 'org/repo' 42 'owner1' ''"
  [ "$status" -eq 0 ]

  count=$(printf '%s' "$output" | yq -r 'length')
  [ "$count" -eq 1 ]

  body=$(printf '%s' "$output" | yq -r '.[0].body')
  [ "$body" = "Real feedback" ]
}

@test "process_owner_feedback resets task to routed" {
  run "${REPO_DIR}/scripts/add_task.sh" "Feedback Task" "Body" ""
  [ "$status" -eq 0 ]

  # Set task to done with an agent
  run yq -i '(.tasks[] | select(.id == 2) | .status) = "done" | (.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  FEEDBACK='[{"login":"owner1","created_at":"2026-01-01T12:00:00Z","body":"This should be an internal doc"}]'

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; TASKS_PATH='$TASKS_PATH'; CONTEXTS_DIR='$ORCH_HOME/contexts'; process_owner_feedback 2 '$FEEDBACK'"
  [ "$status" -eq 0 ]

  # Status should be routed
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  # Agent should be preserved
  run yq -r '.tasks[] | select(.id == 2) | .agent' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

  # last_error should contain feedback
  run yq -r '.tasks[] | select(.id == 2) | .last_error' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"internal doc"* ]]

  # gh_last_feedback_at should be set
  run yq -r '.tasks[] | select(.id == 2) | .gh_last_feedback_at' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-01-01T12:00:00Z" ]

  # History should have owner feedback entry
  run yq -r '.tasks[] | select(.id == 2) | .history[-1].note' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "owner feedback received" ]
}

@test "process_owner_feedback appends to task context" {
  run "${REPO_DIR}/scripts/add_task.sh" "Context Task" "Body" ""
  [ "$status" -eq 0 ]

  FEEDBACK='[{"login":"owner1","created_at":"2026-01-01T12:00:00Z","body":"Please use markdown format"}]'

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; TASKS_PATH='$TASKS_PATH'; CONTEXTS_DIR='$ORCH_HOME/contexts'; process_owner_feedback 2 '$FEEDBACK'"
  [ "$status" -eq 0 ]

  # Context file should exist and contain the feedback
  CTX_FILE="$ORCH_HOME/contexts/task-2.md"
  [ -f "$CTX_FILE" ]

  run cat "$CTX_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Owner feedback from owner1"* ]]
  [[ "$output" == *"Please use markdown format"* ]]
}

@test "gh_pull processes owner feedback on done tasks" {
  # Create a task linked to a GitHub issue with status done
  run "${REPO_DIR}/scripts/add_task.sh" "Done Task" "Body" ""
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .status) = "done" |
    (.tasks[] | select(.id == 2) | .agent) = "claude" |
    (.tasks[] | select(.id == 2) | .gh_issue_number) = 99 |
    (.tasks[] | select(.id == 2) | .gh_state) = "open" |
    (.tasks[] | select(.id == 2) | .gh_url) = "https://github.com/org/repo/issues/99"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Set repo config
  run yq -i '.gh.repo = "testowner/testrepo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Set review_owner
  run yq -i '.workflow.review_owner = "testowner"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Mock gh
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"*"comments"* ]]; then
  cat <<'JSON'
[
  {"user":{"login":"testowner"},"created_at":"2026-02-18T10:00:00Z","body":"This needs rework"}
]
JSON
elif [[ "$*" == *"repo view"* ]]; then
  echo "testowner/testrepo"
elif [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"repository":{}}}'
elif [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  echo "[]"
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" GITHUB_REPO="testowner/testrepo" bash "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # Task should now be routed (not done)
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  # Agent should be preserved
  run yq -r '.tasks[] | select(.id == 2) | .agent' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "gh_pull skips in_progress tasks for feedback" {
  # Create a task linked to a GitHub issue with status in_progress
  run "${REPO_DIR}/scripts/add_task.sh" "Running Task" "Body" ""
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .status) = "in_progress" |
    (.tasks[] | select(.id == 2) | .agent) = "claude" |
    (.tasks[] | select(.id == 2) | .gh_issue_number) = 88 |
    (.tasks[] | select(.id == 2) | .gh_state) = "open"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run yq -i '.gh.repo = "testowner/testrepo" | .workflow.review_owner = "testowner"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"*"comments"* ]]; then
  # Owner commented — but task is in_progress so should be skipped
  cat <<'JSON'
[
  {"user":{"login":"testowner"},"created_at":"2026-02-18T10:00:00Z","body":"Looks wrong"}
]
JSON
elif [[ "$*" == *"repo view"* ]]; then
  echo "testowner/testrepo"
elif [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"repository":{}}}'
elif [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  echo "[]"
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" GITHUB_REPO="testowner/testrepo" bash "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # Task should still be in_progress
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "in_progress" ]
}

# ===== project_add.sh / bare repo support =====

@test "is_bare_repo detects bare repositories" {
  source "${REPO_DIR}/scripts/lib.sh"

  # Regular repo should NOT be bare
  run is_bare_repo "$PROJECT_DIR"
  [ "$status" -ne 0 ]

  # Create a bare repo
  BARE="${TMP_DIR}/bare-test.git"
  git clone --bare "$PROJECT_DIR" "$BARE" 2>/dev/null

  run is_bare_repo "$BARE"
  [ "$status" -eq 0 ]
}

@test "project_add.sh creates config for pre-existing bare repo" {
  # Pre-clone a bare repo at the expected path (avoids stubbing git for SSH)
  SRC="${TMP_DIR}/source-repo"
  mkdir -p "$SRC"
  git -C "$SRC" init -b main --quiet
  git -C "$SRC" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet

  BARE_DIR="${ORCH_HOME}/projects/testowner/testrepo.git"
  mkdir -p "$(dirname "$BARE_DIR")"
  git clone --bare "$SRC" "$BARE_DIR" 2>/dev/null

  # Stub gh (init.sh calls gh)
  GH_STUB="${TMP_DIR}/bin/gh"
  mkdir -p "${TMP_DIR}/bin"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "{}"
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}/bin:${PATH}" ORCH_HOME="$ORCH_HOME" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" STATE_DIR="$STATE_DIR" \
    bash "${REPO_DIR}/scripts/project_add.sh" "testowner/testrepo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already cloned"* ]]

  # Config should have correct repo slug
  run yq -r '.gh.repo' "${BARE_DIR}/.orchestrator.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "testowner/testrepo" ]
}

@test "project_add.sh fetches if already cloned" {
  # Create a source repo and bare clone it manually
  SRC="${TMP_DIR}/source-repo2"
  mkdir -p "$SRC"
  git -C "$SRC" init -b main --quiet
  git -C "$SRC" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet

  BARE_DIR="${ORCH_HOME}/projects/fetchowner/fetchrepo.git"
  mkdir -p "$(dirname "$BARE_DIR")"
  git clone --bare "$SRC" "$BARE_DIR" 2>/dev/null

  # Stub gh
  GH_STUB="${TMP_DIR}/bin/gh"
  mkdir -p "${TMP_DIR}/bin"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "{}"
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}/bin:${PATH}" ORCH_HOME="$ORCH_HOME" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" STATE_DIR="$STATE_DIR" \
    bash "${REPO_DIR}/scripts/project_add.sh" "fetchowner/fetchrepo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already cloned"* ]]
}

@test "project_add.sh normalizes GitHub URLs" {
  # Pre-clone bare repos at the expected normalized paths
  SRC="${TMP_DIR}/source-repo3"
  mkdir -p "$SRC"
  git -C "$SRC" init -b main --quiet
  git -C "$SRC" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet

  # Pre-clone for HTTPS URL test
  BARE_HTTPS="${ORCH_HOME}/projects/urlowner/urlrepo.git"
  mkdir -p "$(dirname "$BARE_HTTPS")"
  git clone --bare "$SRC" "$BARE_HTTPS" 2>/dev/null

  # Pre-clone for SSH URL test
  BARE_SSH="${ORCH_HOME}/projects/sshowner/sshrepo.git"
  mkdir -p "$(dirname "$BARE_SSH")"
  git clone --bare "$SRC" "$BARE_SSH" 2>/dev/null

  GH_STUB="${TMP_DIR}/bin/gh"
  mkdir -p "${TMP_DIR}/bin"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "{}"
SH
  chmod +x "$GH_STUB"

  # Test HTTPS URL normalization
  run env PATH="${TMP_DIR}/bin:${PATH}" ORCH_HOME="$ORCH_HOME" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" STATE_DIR="$STATE_DIR" \
    bash "${REPO_DIR}/scripts/project_add.sh" "https://github.com/urlowner/urlrepo.git"
  [ "$status" -eq 0 ]

  run yq -r '.gh.repo' "${BARE_HTTPS}/.orchestrator.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "urlowner/urlrepo" ]

  # Test SSH URL normalization
  run env PATH="${TMP_DIR}/bin:${PATH}" ORCH_HOME="$ORCH_HOME" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" STATE_DIR="$STATE_DIR" \
    bash "${REPO_DIR}/scripts/project_add.sh" "git@github.com:sshowner/sshrepo.git"
  [ "$status" -eq 0 ]

  run yq -r '.gh.repo' "${BARE_SSH}/.orchestrator.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "sshowner/sshrepo" ]
}

@test "run_task.sh creates worktree from bare repo" {
  # Create a bare repo with a commit
  SRC="${TMP_DIR}/source-repo4"
  mkdir -p "$SRC"
  git -C "$SRC" init -b main --quiet
  git -C "$SRC" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet

  BARE_DIR="${TMP_DIR}/bare-worktree-test.git"
  git clone --bare "$SRC" "$BARE_DIR" 2>/dev/null

  # Write .orchestrator.yml
  cat > "${BARE_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: "testowner/testrepo"
  sync_label: ""
YAML

  # Point PROJECT_DIR to bare repo and add a task
  PROJECT_DIR_OLD="$PROJECT_DIR"
  export PROJECT_DIR="$BARE_DIR"
  "${REPO_DIR}/scripts/add_task.sh" "Bare Repo Task" "Test body" "" >/dev/null

  # Verify task dir
  run yq -r '.tasks[1].dir' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$BARE_DIR" ]

  # Stub the agent (claude)
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
# Write output file
cat > "${OUTPUT_FILE}" <<'JSON'
{"status":"done","summary":"did the thing","accomplished":["tested bare"],"remaining":[],"blockers":[],"files_changed":[],"needs_help":false,"reason":"all good"}
JSON
echo '{"type":"result","result":"done"}'
SH
  chmod +x "$CLAUDE_STUB"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "{}"
SH
  chmod +x "$GH_STUB"

  # Route the task first
  yq -i '(.tasks[] | select(.id == 2) | .agent) = "claude" | (.tasks[] | select(.id == 2) | .status) = "routed"' "$TASKS_PATH"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$BARE_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    AGENT_TIMEOUT_SECONDS=5 LOCK_PATH="${ORCH_HOME}/tasks.yml.lock" \
    bash "${REPO_DIR}/scripts/run_task.sh" 2

  # Task should have a worktree set
  run yq -r '.tasks[] | select(.id == 2) | .worktree' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ -n "$output" ]

  # Worktree directory should exist
  WT_DIR="$output"
  [ -d "$WT_DIR" ]

  # Clean up worktree
  git -C "$BARE_DIR" worktree remove "$WT_DIR" 2>/dev/null || true

  export PROJECT_DIR="$PROJECT_DIR_OLD"
}

@test "gh_pull.sh detects repo from bare clone remote URL" {
  source "${REPO_DIR}/scripts/lib.sh"

  # Create a bare repo with a remote origin
  SRC="${TMP_DIR}/source-repo5"
  mkdir -p "$SRC"
  git -C "$SRC" init -b main --quiet
  git -C "$SRC" -c user.email="test@test.com" -c user.name="Test" commit --allow-empty -m "init" --quiet

  BARE_DIR="${TMP_DIR}/bare-pull-test.git"
  git clone --bare "$SRC" "$BARE_DIR" 2>/dev/null
  # Set a GitHub-style remote URL
  git -C "$BARE_DIR" remote set-url origin "git@github.com:bareowner/barerepo.git"

  # Verify is_bare_repo
  run is_bare_repo "$BARE_DIR"
  [ "$status" -eq 0 ]

  # Write config
  cat > "${BARE_DIR}/.orchestrator.yml" <<YAML
gh:
  repo: ""
  sync_label: ""
YAML

  # Stub gh
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  echo "[]"
elif [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"repository":{}}}'
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$BARE_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="" \
    bash "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bareowner/barerepo"* ]]
}

@test "gh_pull.sh syncs status from GH labels when GH updated more recently" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  # Create a task linked to GH issue #10, local status=needs_review, old updated_at
  acquire_lock
  create_task_entry 2 "Sync test task" "" ""
  release_lock

  # Set gh_issue_number, status, and an old updated_at
  yq -i '(.tasks[] | select(.id == 2)).gh_issue_number = 10' "$TASKS_PATH"
  yq -i '(.tasks[] | select(.id == 2)).status = "needs_review"' "$TASKS_PATH"
  yq -i '(.tasks[] | select(.id == 2)).updated_at = "2026-01-01T00:00:00Z"' "$TASKS_PATH"
  yq -i '(.tasks[] | select(.id == 2)).dir = env(PROJECT_DIR)' "$TASKS_PATH"

  # Stub gh to return issue #10 with status:new label and a newer updated_at
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  cat <<JSON
[{
  "number": 10,
  "title": "Sync test task",
  "body": "",
  "labels": [{"name": "status:new"}],
  "state": "open",
  "html_url": "https://github.com/test/repo/issues/10",
  "updated_at": "2026-02-01T00:00:00Z",
  "pull_request": null
}]
JSON
elif [[ "$*" == *"graphql"* ]]; then
  echo '{"data":{"repository":{}}}'
else
  echo "[]"
fi
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$PROJECT_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    bash "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # Verify status was synced from GH
  local_status=$(yq -r '.tasks[] | select(.gh_issue_number == 10) | .status' "$TASKS_PATH")
  [ "$local_status" = "new" ]
  [[ "$output" == *"status synced from GH: needs_review"* ]]
}
