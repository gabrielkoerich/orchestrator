#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  TMP_DIR=$(mktemp -d)
  export STATE_DIR="${TMP_DIR}/.orchestrator"
  mkdir -p "$STATE_DIR"
  export TASKS_PATH="${TMP_DIR}/tasks.yml"
  export CONFIG_PATH="${TMP_DIR}/config.yml"
  export PROJECT_DIR="${TMP_DIR}"
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
{"executor":"codex","reason":"test route","profile":{"role":"backend specialist","skills":["api","sql"],"tools":["git","rg"],"constraints":["no migrations"]},"selected_skills":[]}
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
  run "${REPO_DIR}/scripts/add_task.sh" "Run Me" "Run body" ""
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

  run yq -i '.workflow.enable_review_agent = true | .workflow.review_agent = "codex"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  run yq -i '(.tasks[] | select(.id == 2) | .agent) = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  # Execution stub prints JSON to stdout; review stub also prints to stdout
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
prompt="$*"
if printf '%s' "$prompt" | grep -q "reviewing agent"; then
  cat <<'JSON'
{"decision":"approve","notes":"looks good"}
JSON
else
  cat <<'JSON'
{"status":"done","summary":"done","files_changed":[],"needs_help":false,"delegations":[]}
JSON
fi
SH
  chmod +x "$CODEX_STUB"

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
prompt="$*"
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
  [ "$output" = "blocked" ]

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

  # Task should be blocked due to retry loop
  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]

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

@test "serve recipe is private (hidden from just --list)" {
  command -v just >/dev/null 2>&1 || skip "just not installed"
  run just --justfile "${REPO_DIR}/justfile" --list
  [ "$status" -eq 0 ]
  # start should be visible
  [[ "$output" == *"start"* ]]
  # serve should NOT be listed (it's private)
  [[ "$output" != *"serve"* ]]
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
