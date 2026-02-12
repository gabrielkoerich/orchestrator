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

  # Stub writes output file instead of printing to stdout
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<SH
#!/usr/bin/env bash
cat > "${STATE_DIR}/output-2.json" <<'JSON'
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

  # Stub writes output file (task 2 will be re-run after rejoin)
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<SH
#!/usr/bin/env bash
cat > "${STATE_DIR}/output-2.json" <<'JSON'
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

  # Execution stub writes output file; review stub prints to stdout
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<SH
#!/usr/bin/env bash
prompt="\$*"
if printf '%s' "\$prompt" | grep -q "reviewing agent"; then
  cat <<'JSON'
{"decision":"approve","notes":"looks good"}
JSON
else
  cat > "${STATE_DIR}/output-2.json" <<'JSON'
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

@test "run_task.sh reads output from file" {
  run "${REPO_DIR}/scripts/add_task.sh" "Output File" "Test output file reading" ""
  [ "$status" -eq 0 ]

  # Stub writes JSON to output file
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<SH
#!/usr/bin/env bash
cat > "${STATE_DIR}/output-2.json" <<'JSON'
{"status":"done","summary":"wrote output file","accomplished":["task completed"],"remaining":[],"blockers":[],"files_changed":["test.txt"],"needs_help":false,"delegations":[]}
JSON
echo "agent stdout (should be ignored)"
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

  # Stub that checks which prompt it receives
  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<SH
#!/usr/bin/env bash
# Check if the plan prompt is being used (contains "planning agent")
prompt="\$*"
if printf '%s' "\$prompt" | grep -q "planning agent"; then
  cat > "${STATE_DIR}/output-2.json" <<'JSON'
{"status":"done","summary":"planned the work","accomplished":["analyzed task"],"remaining":[],"blockers":[],"files_changed":[],"needs_help":false,"reason":"","delegations":[{"title":"Step 1","body":"Do first thing","labels":["backend"],"suggested_agent":"codex"},{"title":"Step 2","body":"Do second thing","labels":["tests"],"suggested_agent":"codex"}]}
JSON
else
  cat > "${STATE_DIR}/output-2.json" <<'JSON'
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
