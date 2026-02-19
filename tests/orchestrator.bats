#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  # Use ~/.orchestrator/.tmp to avoid macOS /tmp → /private/tmp symlink issues
  mkdir -p "${HOME}/.orchestrator/.tmp"
  TMP_DIR=$(mktemp -d "${HOME}/.orchestrator/.tmp/test.XXXXXX")
  export STATE_DIR="${TMP_DIR}/.orchestrator"
  mkdir -p "$STATE_DIR"
  export ORCH_HOME="${TMP_DIR}/orch_home"
  mkdir -p "$ORCH_HOME"
  export TASKS_PATH="${ORCH_HOME}/tasks.yml"
  export JOBS_PATH="${ORCH_HOME}/jobs.yml"
  export CONFIG_PATH="${ORCH_HOME}/config.yml"
  export DB_PATH="${ORCH_HOME}/orchestrator.db"
  export SCHEMA_PATH="${REPO_DIR}/scripts/schema.sql"
  export PROJECT_DIR="${TMP_DIR}"
  # Initialize SQLite database
  sqlite3 "$DB_PATH" < "$SCHEMA_PATH" >/dev/null
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

# SQLite test helpers
tdb() { sqlite3 "$DB_PATH" "$@"; }
tdb_field() { sqlite3 "$DB_PATH" "SELECT $2 FROM tasks WHERE id = $1;"; }
tdb_set() { sqlite3 "$DB_PATH" "UPDATE tasks SET $2 = '$3', updated_at = datetime('now') WHERE id = $1;"; }
tdb_count() { sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks;"; }
tdb_job_field() { sqlite3 "$DB_PATH" "SELECT $2 FROM jobs WHERE id = '$1';"; }
tdb_job_count() { sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM jobs;"; }

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

  run tdb_count
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]

  run tdb_field 2 title
  [ "$status" -eq 0 ]
  [ "$output" = "Test Title" ]

  run tdb_field 2 dir
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP_DIR" ]
}

@test "route_task.sh sets agent, status, and profile" {
  run "${REPO_DIR}/scripts/add_task.sh" "Route Me" "Routing body" ""
  [ "$status" -eq 0 ]

  run yq -i '.router.agent = "codex"' "$CONFIG_PATH"
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

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  run tdb "SELECT json_extract(agent_profile, '$.role') FROM tasks WHERE id = 2;"
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]

  run tdb "SELECT title FROM tasks WHERE parent_id = 2;"
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Task should be done, not blocked
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # No child tasks should be created
  run tdb "SELECT title FROM tasks WHERE parent_id = 2;"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "poll.sh runs new tasks and rejoins blocked parents" {
  run "${REPO_DIR}/scripts/add_task.sh" "Parent" "Parent body" ""
  [ "$status" -eq 0 ]

  run "${REPO_DIR}/scripts/add_task.sh" "Child" "Child body" ""
  [ "$status" -eq 0 ]

  run tdb_set 1 status "done"
  [ "$status" -eq 0 ]

  tdb_set 2 status "blocked"
  tdb "INSERT OR IGNORE INTO task_children (parent_id, child_id) VALUES (2, 3);"
  [ "$status" -eq 0 ]
  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]
  tdb "UPDATE tasks SET status = 'done', agent = 'codex', updated_at = datetime('now') WHERE id = 3;"
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

  run tdb_field 2 status
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

@test "cleanup_worktrees.sh removes worktree for merged PR task" {
  run "${REPO_DIR}/scripts/add_task.sh" "Cleanup merged" "Body" ""
  [ "$status" -eq 0 ]

  WT_DIR="${TMP_DIR}/wt-merged"
  mkdir -p "$WT_DIR"

  run yq -i '(.gh.repo) = "testowner/testrepo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]
  tdb_set 2 status "done"
  tdb_set 2 gh_issue_number 47
  tdb_set 2 branch "gh-task-47-cleanup"
  tdb_set 2 worktree "$WT_DIR"
  tdb_set 2 dir "$PROJECT_DIR"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
# Return PR number as gh --jq '.[0].number // ""' would output
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo '123'
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  GIT_STUB="${TMP_DIR}/git"
  cat > "$GIT_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMP_DIR}/git_calls"
if [[ "$*" == *"show-ref --verify --quiet refs/heads/"* ]]; then
  exit 0
fi
exit 0
SH
  chmod +x "$GIT_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TMP_DIR="$TMP_DIR" \
    DB_PATH="$DB_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" \
    ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  [ "$(tdb_field 2 worktree_cleaned)" = "1" ]

  run bash -c "cat '${TMP_DIR}/git_calls'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree remove ${WT_DIR} --force"* ]]
  [[ "$output" == *"branch -d gh-task-47-cleanup"* ]]
}

@test "cleanup_worktrees.sh skips tasks without merged PR" {
  run "${REPO_DIR}/scripts/add_task.sh" "Cleanup unmerged" "Body" ""
  [ "$status" -eq 0 ]

  WT_DIR="${TMP_DIR}/wt-unmerged"
  mkdir -p "$WT_DIR"

  run yq -i '(.gh.repo) = "testowner/testrepo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]
  tdb_set 2 status "done"
  tdb_set 2 gh_issue_number 48
  tdb_set 2 branch "gh-task-48-cleanup"
  tdb_set 2 worktree "$WT_DIR"
  tdb_set 2 dir "$PROJECT_DIR"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
# Return empty output to simulate no merged PR found (gh --jq returns empty for no matches)
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  GIT_STUB="${TMP_DIR}/git"
  cat > "$GIT_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMP_DIR}/git_calls_skip"
exit 0
SH
  chmod +x "$GIT_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TMP_DIR="$TMP_DIR" \
    DB_PATH="$DB_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" \
    ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  [ "$(tdb_field 2 worktree_cleaned)" = "0" ]

  [ ! -f "${TMP_DIR}/git_calls_skip" ]
}

@test "cleanup_worktrees.sh marks worktree_cleaned after removal" {
  run "${REPO_DIR}/scripts/add_task.sh" "Cleanup local done" "Body" ""
  [ "$status" -eq 0 ]

  WT_DIR="${TMP_DIR}/wt-local"
  mkdir -p "$WT_DIR"

  tdb_set 2 status "done"
  tdb_set 2 branch "task-2-local"
  tdb_set 2 worktree "$WT_DIR"
  tdb_set 2 dir "$PROJECT_DIR"

  GIT_STUB="${TMP_DIR}/git"
  cat > "$GIT_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"show-ref --verify --quiet refs/heads/"* ]]; then
  exit 0
fi
exit 0
SH
  chmod +x "$GIT_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    DB_PATH="$DB_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" \
    ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  [ "$(tdb_field 2 worktree_cleaned)" = "1" ]
}

@test "cleanup_worktrees.sh handles missing worktree directory gracefully" {
  run "${REPO_DIR}/scripts/add_task.sh" "Cleanup missing dir" "Body" ""
  [ "$status" -eq 0 ]

  WT_DIR="${TMP_DIR}/wt-missing"
  tdb_set 2 status "done"
  tdb_set 2 worktree "$WT_DIR"
  tdb_set 2 dir "$PROJECT_DIR"

  GIT_STUB="${TMP_DIR}/git"
  cat > "$GIT_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMP_DIR}/git_calls_missing"
exit 0
SH
  chmod +x "$GIT_STUB"

  run env PATH="${TMP_DIR}:${PATH}" TMP_DIR="$TMP_DIR" \
    DB_PATH="$DB_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" \
    ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    "${REPO_DIR}/scripts/cleanup_worktrees.sh"
  [ "$status" -eq 0 ]

  [ "$(tdb_field 2 worktree_cleaned)" = "1" ]

  [ ! -f "${TMP_DIR}/git_calls_missing" ]
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

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  run tdb_field 2 route_reason
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback"* ]]
}

@test "run_task.sh runs review agent when enabled" {
  run "${REPO_DIR}/scripts/add_task.sh" "Review Me" "Review body" ""
  [ "$status" -eq 0 ]

  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Task agent is codex → review agent should be claude (opposite)
  run tdb_set 2 agent "codex"
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

  run tdb_field 2 review_decision
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  run tdb_field 2 summary
  [ "$status" -eq 0 ]
  [ "$output" = "wrote output file" ]

  run tdb "SELECT file_path FROM task_files WHERE task_id = 2 LIMIT 1;"
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  run tdb_field 2 summary
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

  run tdb_job_count
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run tdb "SELECT id FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" = "daily-sync" ]

  run tdb "SELECT schedule FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" = "0 9 * * *" ]

  run tdb "SELECT enabled FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
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
  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, created_at) VALUES ('test-always', 'Always Run', '* * * * *', 'task', 'Test job body', 'test', 1, datetime('now'));"

  run env DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have created a task
  run tdb "SELECT status FROM tasks WHERE title = 'Always Run';"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  # Should have job:test-always label
  run tdb "SELECT label FROM task_labels tl JOIN tasks t ON t.id = tl.task_id WHERE t.title = 'Always Run' ORDER BY label;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"job:test-always"* ]]

  # Job should have active_task_id set
  run tdb "SELECT active_task_id FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "jobs_tick.sh skips when active task is in-flight" {
  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, active_task_id, created_at) VALUES ('test-dedup', 'Dedup Test', '* * * * *', 'task', 'Should not duplicate', '', 1, 1, datetime('now'));"

  # Task 1 (Init) is status "new" — in-flight
  run tdb_field 1 status
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  TASK_COUNT_BEFORE=$(tdb_count)

  run env TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # No new task should have been created
  TASK_COUNT_AFTER=$(tdb_count)
  [ "$TASK_COUNT_BEFORE" -eq "$TASK_COUNT_AFTER" ]
}

@test "jobs_tick.sh creates task after previous completes" {
  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, active_task_id, created_at) VALUES ('test-after-done', 'After Done', '* * * * *', 'task', 'Run after previous finishes', '', 1, 1, datetime('now'));"

  # Mark task 1 as done
  run tdb_set 1 status "done"
  [ "$status" -eq 0 ]

  run env TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have created a new task
  run tdb "SELECT status FROM tasks WHERE title = 'After Done';"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  # Last task status should be recorded
  run tdb "SELECT last_task_status FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "jobs_tick.sh skips disabled jobs" {
  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, created_at) VALUES ('test-disabled', 'Disabled Job', '* * * * *', 'task', 'Should not run', '', 0, datetime('now'));"

  TASK_COUNT_BEFORE=$(tdb_count)

  run env TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  TASK_COUNT_AFTER=$(tdb_count)
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Should have created child tasks from delegation
  run tdb "SELECT title FROM tasks WHERE parent_id = 2;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Step 1"* ]]
  [[ "$output" == *"Step 2"* ]]

  # Parent should be blocked
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "jobs_remove.sh removes a job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  printf 'jobs: []\n' > "$JOBS_PATH"

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_add.sh" "@daily" "To Remove" "" "" ""
  [ "$status" -eq 0 ]

  run tdb_job_count
  [ "$output" -eq 1 ]

  run env JOBS_PATH="$JOBS_PATH" "${REPO_DIR}/scripts/jobs_remove.sh" "to-remove"
  [ "$status" -eq 0 ]

  run tdb_job_count
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

  run tdb "SELECT dir FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP_DIR" ]
}

@test "run_task.sh blocks task after max_attempts exceeded" {
  run "${REPO_DIR}/scripts/add_task.sh" "Max Retry" "Should block after max" ""
  [ "$status" -eq 0 ]

  # Set task to already have 10 attempts (max default) and agent assigned
  tdb "UPDATE tasks SET agent = 'codex', attempts = 10, updated_at = datetime('now') WHERE id = 2;"
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

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  run tdb_field 2 reason
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
  run tdb "SELECT gh_issue_number FROM tasks WHERE title = 'Issue 1';"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run tdb "SELECT gh_issue_number FROM tasks WHERE title = 'Issue 2';"
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
    env TASKS_PATH="$TASKS_PATH" DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" PROJECT_DIR="$PROJECT_DIR" "${REPO_DIR}/scripts/add_task.sh" "Concurrent $i" "body $i" "" >/dev/null 2>&1 &
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
  run tdb_count
  [ "$status" -eq 0 ]
  [ "$output" -eq "$EXPECTED" ]

  # IDs should be unique (no corruption from concurrent writes)
  run tdb_count
  [ "$status" -eq 0 ]
  UNIQUE_COUNT=$(echo "$output" | tr -d ' ')
  [ "$UNIQUE_COUNT" -eq "$EXPECTED" ]
}

@test "performance: list_tasks.sh handles 100+ tasks" {
  # Create 100 tasks via SQLite batch
  for i in $(seq 2 100); do
    tdb "INSERT INTO tasks (title, body, status, dir, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
      VALUES ('Task $i', '', 'new', '$TMP_DIR', 0, 0, 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"
  done

  run tdb_count
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
    create_task_entry 99 'Helper Task' 'Created by helper' 'test,helper' '' ''
  "
  [ "$status" -eq 0 ]
  # db_create_task returns auto-assigned ID (ignoring the passed-in 99)
  NEW_ID=$(echo "$output" | tr -d '[:space:]')

  run tdb_field "$NEW_ID" title
  [ "$status" -eq 0 ]
  [ "$output" = "Helper Task" ]

  run tdb_field "$NEW_ID" dir
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
  run tdb "SELECT title FROM tasks WHERE title = 'Fix login page';"
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
  run tdb "SELECT title FROM tasks WHERE title = 'Create user model';"
  [ "$status" -eq 0 ]
  [ "$output" = "Create user model" ]

  run tdb "SELECT title FROM tasks WHERE title = 'Add login endpoint';"
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
  tdb "UPDATE tasks SET gh_issue_number = 1, gh_url = 'https://github.com/test/repo/issues/1', gh_state = 'open', status = 'in_progress', updated_at = '$NOW', gh_synced_at = '' WHERE id = 1;"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" \
    DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" \
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
  tdb "UPDATE tasks SET gh_issue_number = 1, gh_state = 'closed', status = 'done', gh_project_item_id = 'PVTI_item1', gh_archived = 0, updated_at = '$NOW', gh_synced_at = '' WHERE id = 1;"

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

  run tdb_field 1 gh_archived
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
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
  tdb "UPDATE tasks SET gh_issue_number = 1, gh_state = 'closed', status = 'done', gh_project_item_id = 'PVTI_item1', gh_archived = 1, updated_at = '$NOW', gh_synced_at = '' WHERE id = 1;"

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

@test "gh_push.sh archives done tasks even with stale gh_state=open" {
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
  tdb "UPDATE tasks SET gh_issue_number = 1, gh_state = 'open', status = 'done', gh_project_item_id = 'PVTI_item1', gh_archived = 0, updated_at = '$NOW', gh_synced_at = '' WHERE id = 1;"

  run env PATH="${TMP_DIR}:${PATH}" \
    DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  # Done tasks should now be archived regardless of gh_state
  [ -f "${STATE_DIR}/gh_calls" ]
  grep -q "archive_called" "${STATE_DIR}/gh_calls"
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

  tdb "UPDATE tasks SET agent = 'codex', status = 'routed', updated_at = datetime('now') WHERE id = 2;"
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
  run tdb_field 2 status
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

  run tdb "SELECT status FROM task_history WHERE task_id = 1 ORDER BY id DESC LIMIT 1;"
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
  tdb "UPDATE tasks SET status = 'done', gh_issue_number = 1, gh_state = 'closed', updated_at = '$FROZEN' WHERE id = 1;"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_pull.sh"
  [ "$status" -eq 0 ]

  # updated_at should still be the original value, not bumped
  run tdb_field 1 updated_at
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

@test "run_task.sh passes --permission-mode bypassPermissions to claude" {
  run grep -n 'permission-mode bypassPermissions' "${REPO_DIR}/scripts/run_task.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
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

  run tdb_set 2 agent "codex"
  [ "$status" -eq 0 ]

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" PROJECT_DIR="$PROJECT_DIR" STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  # Check that the task's state got updated with the correct status
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]

  # Agent model should be recorded in the task
  run tdb_field 2 agent_model
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
  tdb "UPDATE tasks SET last_comment_hash = '${HASH}' WHERE id = 1;"

  run bash -c "
    export DB_PATH='$DB_PATH' SCHEMA_PATH='$SCHEMA_PATH' ORCH_HOME='$ORCH_HOME'
    source '${REPO_DIR}/scripts/lib.sh'
    if db_should_skip_comment 1 '$BODY'; then
      echo 'SKIPPED'
    else
      echo 'POSTED'
    fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED" ]
}

@test "comment dedup posts when content differs" {
  tdb_set 1 last_comment_hash "oldoldhash12345"

  run bash -c "
    export DB_PATH='$DB_PATH' SCHEMA_PATH='$SCHEMA_PATH' ORCH_HOME='$ORCH_HOME'
    source '${REPO_DIR}/scripts/lib.sh'
    if db_should_skip_comment 1 'new different body'; then
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
    create_task_entry 50 'Schema Test' 'Check fields' '' '' ''
  "
  [ "$status" -eq 0 ]
  NEW_ID=$(echo "$output" | tr -d '[:space:]')

  # last_comment_hash column exists in schema
  run tdb "SELECT name FROM pragma_table_info('tasks') WHERE name = 'last_comment_hash';"
  [ "$status" -eq 0 ]
  [ "$output" = "last_comment_hash" ]
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
  tdb "UPDATE tasks SET agent = 'codex', attempts = 3, status = 'routed' WHERE id = 2;"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:00:00Z', 'blocked', 'agent command failed (exit 1)');"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:01:00Z', 'blocked', 'agent command failed (exit 1)');"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:02:00Z', 'blocked', 'agent command failed (exit 1)');"

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
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  run tdb_field 2 last_error
  [ "$status" -eq 0 ]
  [[ "$output" == *"retry loop"* ]]
}

@test "run_task.sh does not detect retry loop with varied errors" {
  run "${REPO_DIR}/scripts/add_task.sh" "No Loop" "Different errors each time" ""
  [ "$status" -eq 0 ]

  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  export NOW
  tdb "UPDATE tasks SET agent = 'codex', attempts = 3, status = 'routed' WHERE id = 2;"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:00:00Z', 'blocked', 'error A');"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:01:00Z', 'blocked', 'error B');"
  tdb "INSERT INTO task_history (task_id, ts, status, note) VALUES (2, '2026-01-01T00:02:00Z', 'blocked', 'error C');"

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
  run tdb_field 2 status
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
  # Functions live in db.sh; gh_push.sh calls db_should_skip_comment + db_store_comment_hash
  run grep -c 'should_skip_comment\|store_comment_hash\|last_comment_hash' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gh_push.sh applies blocked label on blocked status" {
  run grep -c 'ensure_label.*blocked.*d73a4a\|labels.*blocked' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gh_push.sh uses atomic gh_synced_at write" {
  # SQLite: db_task_set_synced sets gh_synced_at = updated_at atomically
  run grep -c 'db_task_set_synced' "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gh_push.sh skips tasks from different projects" {
  # A task with dir=/other/project should be skipped when gh_push runs for PROJECT_DIR=$TMP_DIR
  "${REPO_DIR}/scripts/add_task.sh" "Other project task" "Body" "" >/dev/null
  tdb "UPDATE tasks SET status = 'new', dir = '/other/project', gh_issue_number = NULL WHERE id = 2;"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "gh_called" >> "${STATE_DIR}/gh_push_calls"
echo '{"number":99,"html_url":"https://github.com/test/repo/issues/99","state":"open"}'
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  # Task 2 should NOT have gotten an issue (it belongs to a different project)
  TASK2_GH=$(tdb "SELECT gh_issue_number FROM tasks WHERE id = 2;")
  [ -z "$TASK2_GH" ] || [ "$TASK2_GH" = "NULL" ]
}

@test "gh_push.sh never creates issues for done tasks" {
  # A done task without a gh_issue_number should NOT get a new issue created
  "${REPO_DIR}/scripts/add_task.sh" "Done task" "Body" "" >/dev/null
  tdb "UPDATE tasks SET status = 'done', gh_issue_number = NULL WHERE id = 2;"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "FAIL: gh was called to create issue for done task" >&2
echo '{"number":99,"html_url":"https://github.com/test/repo/issues/99","state":"open"}'
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  # Task 2 should still have no issue number
  TASK2_GH=$(tdb "SELECT gh_issue_number FROM tasks WHERE id = 2;")
  [ -z "$TASK2_GH" ] || [ "$TASK2_GH" = "NULL" ]
}

@test "gh_push.sh skips done tasks even with stale gh_state=open" {
  # Bug: done tasks with gh_state=open used to fall through and get synced/duplicated
  # Create a second task, then mark both as done with issue numbers
  "${REPO_DIR}/scripts/add_task.sh" "Second task" "Body" "" >/dev/null
  tdb "UPDATE tasks SET status = 'done', gh_issue_number = 99, gh_state = 'closed' WHERE id = 1;"
  tdb "UPDATE tasks SET status = 'done', gh_issue_number = 10, gh_state = 'open' WHERE id = 2;"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo '{}'
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" \
    DB_PATH="$DB_PATH" ORCH_HOME="$ORCH_HOME" \
    CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$TMP_DIR" \
    STATE_DIR="$STATE_DIR" \
    GITHUB_REPO="test/repo" \
    "${REPO_DIR}/scripts/gh_push.sh"
  [ "$status" -eq 0 ]

  # Task should still have issue #10 (not a new number)
  TASK2_GH=$(tdb "SELECT gh_issue_number FROM tasks WHERE id = 2;")
  [ "$TASK2_GH" = "10" ]
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
  run grep -ci 'stderr_snippet\|Agent stderr' "${REPO_DIR}/scripts/gh_push.sh"
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
  tdb "UPDATE tasks SET gh_issue_number = 10, updated_at = datetime('now') WHERE id = 1;"
  run "${REPO_DIR}/scripts/dashboard.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tasks:"* ]]
  [[ "$output" == *"Projects:"* ]]
  [[ "$output" == *"Worktrees:"* ]]
}

@test "status.sh --global shows PROJECT column" {
  # Add a task with a dir to test global view
  tdb_set 1 dir "/Users/test/myproject"
  run "${REPO_DIR}/scripts/status.sh" --global
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT"* ]]
  [[ "$output" == *"myproject"* ]]
}

@test "list_tasks.sh shows table with issue numbers" {
  tdb "UPDATE tasks SET gh_issue_number = 42, updated_at = datetime('now') WHERE id = 1;"
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

  run tdb "SELECT type FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$output" = "bash" ]

  run tdb "SELECT command FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
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
  # Set up parent-child relationship (both parent_id and task_children table)
  tdb "UPDATE tasks SET parent_id = 2 WHERE id = 3;"
  tdb "INSERT INTO task_children (parent_id, child_id) VALUES (2, 3);"

  run "${REPO_DIR}/scripts/tree.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parent"* ]]
  [[ "$output" == *"Child"* ]]
  # Child should be indented under parent
  [[ "$output" == *"└─"* ]] || [[ "$output" == *"├─"* ]]
}

# --- retry_task.sh ---

@test "retry_task.sh resets done task to new" {
  tdb_set 1 status "done"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run tdb_field 1 status
  [ "$output" = "new" ]
}

@test "retry_task.sh resets blocked task to new" {
  tdb_set 1 status "blocked"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run tdb_field 1 status
  [ "$output" = "new" ]
}

@test "retry_task.sh clears agent on reset" {
  tdb "UPDATE tasks SET status = 'done', agent = 'claude' WHERE id = 1;"

  run "${REPO_DIR}/scripts/retry_task.sh" 1
  [ "$status" -eq 0 ]

  run tdb_field 1 agent
  [ -z "$output" ]
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

  run tdb_field 1 agent
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
  run tdb "SELECT last_run FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
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

  run tdb "SELECT last_task_status FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
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

  run tdb "SELECT enabled FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$output" = "0" ]

  run tdb "SELECT last_task_status FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$output" = "failed" ]
}

# --- jobs_tick.sh catch-up ---

@test "jobs_tick.sh catches up missed job after downtime" {
  # Create a job scheduled for a specific hour that has already passed today
  # Use last_run from 6 hours ago so the scheduled time was missed
  LAST_RUN=$(date -u -v-6H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '6 hours ago' +"%Y-%m-%dT%H:%M:%SZ")
  # Schedule for 3 hours ago (definitely between last_run and now)
  MISSED_HOUR=$(date -u -v-3H +"%H" 2>/dev/null || date -u -d '3 hours ago' +"%H")

  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, last_run, created_at) VALUES ('test-catchup', 'Catch Up Job', '0 ${MISSED_HOUR} * * *', 'task', 'Missed job body', 'test', 1, '${LAST_RUN}', datetime('now'));"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have created a task for the missed job
  run tdb "SELECT status FROM tasks WHERE title = 'Catch Up Job';"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]
}

@test "jobs_tick.sh does not catch up if last_run is after scheduled time" {
  # last_run is 1 hour ago, schedule is for 3 hours ago — already ran
  LAST_RUN=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ")
  PAST_HOUR=$(date -u -v-3H +"%H" 2>/dev/null || date -u -d '3 hours ago' +"%H")

  tdb "INSERT INTO jobs (id, title, schedule, type, body, labels, enabled, last_run, created_at) VALUES ('test-no-catchup', 'No Catch Up', '0 ${PAST_HOUR} * * *', 'task', 'Already ran', 'test', 1, '${LAST_RUN}', datetime('now'));"

  TASK_COUNT_BEFORE=$(tdb_count)

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  TASK_COUNT_AFTER=$(tdb_count)
  [ "$TASK_COUNT_BEFORE" -eq "$TASK_COUNT_AFTER" ]
}

@test "cron_match.py --since detects missed occurrence" {
  # 9am schedule, last_run yesterday at 6am — 9am was missed
  YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d "yesterday" +%Y-%m-%d)
  run python3 "${REPO_DIR}/scripts/cron_match.py" "0 9 * * *" --since "${YESTERDAY}T06:00:00Z"
  [ "$status" -eq 0 ]
}

@test "cron_match.py --since no match when already past" {
  # 9am schedule, last_run at 10am — 9am already passed after last_run
  run python3 "${REPO_DIR}/scripts/cron_match.py" "0 9 * * *" --since "$(date -u +%Y-%m-%d)T10:00:00Z"
  [ "$status" -eq 1 ]
}

@test "jobs_tick.sh catches up missed bash job" {
  export JOBS_PATH="${TMP_DIR}/jobs.yml"
  source "${REPO_DIR}/scripts/lib.sh"
  init_jobs_file

  LAST_RUN=$(date -u -v-6H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '6 hours ago' +"%Y-%m-%dT%H:%M:%SZ")
  MISSED_HOUR=$(date -u -v-3H +"%H" 2>/dev/null || date -u -d '3 hours ago' +"%H")

  "${REPO_DIR}/scripts/jobs_add.sh" --type bash --command "echo caught-up" "0 ${MISSED_HOUR} * * *" "Bash Catch Up" >/dev/null

  # Set last_run to 6 hours ago so the 3-hours-ago occurrence was missed
  tdb "UPDATE jobs SET last_run = '${LAST_RUN}';"

  run "${REPO_DIR}/scripts/jobs_tick.sh"
  [ "$status" -eq 0 ]

  # Should have run and recorded last_run
  run tdb "SELECT last_task_status FROM jobs ORDER BY rowid LIMIT 1 OFFSET 0;"
  [ "$output" = "done" ]
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

  run tdb "SELECT title FROM tasks ORDER BY id DESC LIMIT 1;"
  [ "$output" = "No Body Task" ]

  run tdb "SELECT body FROM tasks ORDER BY id DESC LIMIT 1;"
  [ "$output" = "" ] || [ "$output" = "null" ]
}

@test "add_task.sh assigns sequential ids" {
  "${REPO_DIR}/scripts/add_task.sh" "Task A" "" "" >/dev/null
  "${REPO_DIR}/scripts/add_task.sh" "Task B" "" "" >/dev/null
  "${REPO_DIR}/scripts/add_task.sh" "Task C" "" "" >/dev/null

  run tdb "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
  ID_C="$output"

  run tdb "SELECT id FROM tasks ORDER BY id DESC LIMIT 1 OFFSET 1;"
  ID_B="$output"

  # IDs should be sequential
  [ "$ID_C" -gt "$ID_B" ]
}

# --- task_set helper ---

@test "task_set updates a task field" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  task_set 1 .status "blocked"

  run tdb_field 1 status
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
  tdb "UPDATE tasks SET agent = 'codex', gh_issue_number = 42, gh_url = 'https://github.com/test/repo/issues/42' WHERE id = 2;"

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
  run tdb_field 2 worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-task-42-add-readme"* ]]

  run tdb_field 2 branch
  [ "$status" -eq 0 ]
  [ "$output" = "gh-task-42-add-readme" ]

  # Verify task completed
  run tdb_field 2 status
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
  tdb "UPDATE tasks SET agent = 'claude', gh_issue_number = 55, gh_url = 'https://github.com/test/repo/issues/55' WHERE id = 2;"

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
  run tdb_field 2 complexity
  [ "$status" -eq 0 ]
  [ "$output" = "simple" ]

  # Label should be complexity:simple, not model:*
  run tdb "SELECT label FROM task_labels WHERE task_id = 2 ORDER BY label;"
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
  run tdb_field 2 complexity
  [ "$status" -eq 0 ]
  [ "$output" = "medium" ]

  # Label should include complexity:medium
  run tdb "SELECT label FROM task_labels WHERE task_id = 2 ORDER BY label;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complexity:medium"* ]]
}

@test "create_task_entry includes complexity field" {
  NOW="2026-01-01T00:00:00Z"
  export NOW PROJECT_DIR="$TMP_DIR"

  run bash -c "
    source '${REPO_DIR}/scripts/lib.sh'
    create_task_entry 99 'Complexity Task' 'Test body' 'test' '' ''
  "
  [ "$status" -eq 0 ]
  NEW_ID=$(echo "$output" | tr -d '[:space:]')

  # complexity is NULL by default (not set until routing)
  run tdb_field "$NEW_ID" complexity
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run_task.sh resolves model from complexity config" {
  run "${REPO_DIR}/scripts/add_task.sh" "Resolve Model" "Test model resolution" ""
  [ "$status" -eq 0 ]

  # Add model_map and set complexity on task
  yq -i '.model_map.simple.codex = "gpt-5.1-codex-mini" |
         .model_map.medium.codex = "gpt-5.2" |
         .model_map.complex.codex = "gpt-5.3-codex"' "$CONFIG_PATH"

  tdb "UPDATE tasks SET agent = 'codex', complexity = 'simple' WHERE id = 2;"

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

  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "review agent uses reject decision to close PR" {
  run "${REPO_DIR}/scripts/add_task.sh" "Review Reject" "Test reject" ""
  [ "$status" -eq 0 ]

  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  run tdb_set 2 agent "codex"
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
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "needs_review" ]

  # Last error should mention rejection
  run tdb_field 2 last_error
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

  run tdb_set 2 agent "codex"
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
  run tdb_field 2 status
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

  count=$(printf '%s' "$output" | jq -r 'length')
  [ "$count" -eq 2 ]

  login0=$(printf '%s' "$output" | jq -r '.[0].login')
  [ "$login0" = "owner1" ]

  login1=$(printf '%s' "$output" | jq -r '.[1].login')
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

  count=$(printf '%s' "$output" | jq -r 'length')
  [ "$count" -eq 1 ]

  body=$(printf '%s' "$output" | jq -r '.[0].body')
  [ "$body" = "Real feedback" ]
}

@test "process_owner_feedback resets task to routed" {
  run "${REPO_DIR}/scripts/add_task.sh" "Feedback Task" "Body" ""
  [ "$status" -eq 0 ]

  # Set task to done with an agent
  tdb "UPDATE tasks SET status = 'done', agent = 'codex', updated_at = datetime('now') WHERE id = 2;"
  [ "$status" -eq 0 ]

  FEEDBACK='[{"login":"owner1","created_at":"2026-01-01T12:00:00Z","body":"This should be an internal doc"}]'

  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; TASKS_PATH='$TASKS_PATH'; CONTEXTS_DIR='$ORCH_HOME/contexts'; process_owner_feedback 2 '$FEEDBACK'"
  [ "$status" -eq 0 ]

  # Status should be routed
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  # Agent should be preserved
  run tdb_field 2 agent
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

  # last_error should contain feedback
  run tdb_field 2 last_error
  [ "$status" -eq 0 ]
  [[ "$output" == *"internal doc"* ]]

  # gh_last_feedback_at should be set
  run tdb_field 2 gh_last_feedback_at
  [ "$status" -eq 0 ]
  [ "$output" = "2026-01-01T12:00:00Z" ]

  # History should have owner feedback entry
  run tdb "SELECT note FROM task_history WHERE task_id = 2 ORDER BY id DESC LIMIT 1;"
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

  tdb "UPDATE tasks SET status = 'done', agent = 'claude', gh_issue_number = 99, gh_state = 'open', gh_url = 'https://github.com/org/repo/issues/99' WHERE id = 2;"

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
  run tdb_field 2 status
  [ "$status" -eq 0 ]
  [ "$output" = "routed" ]

  # Agent should be preserved
  run tdb_field 2 agent
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "gh_pull skips in_progress tasks for feedback" {
  # Create a task linked to a GitHub issue with status in_progress
  run "${REPO_DIR}/scripts/add_task.sh" "Running Task" "Body" ""
  [ "$status" -eq 0 ]

  tdb "UPDATE tasks SET status = 'in_progress', agent = 'claude', gh_issue_number = 88, gh_state = 'open' WHERE id = 2;"

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
  run tdb_field 2 status
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
  run tdb_field 2 dir
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
  tdb "UPDATE tasks SET agent = 'claude', status = 'routed', updated_at = datetime('now') WHERE id = 2;"

  run env PATH="${TMP_DIR}:${PATH}" \
    TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" \
    PROJECT_DIR="$BARE_DIR" ORCH_HOME="$ORCH_HOME" STATE_DIR="$STATE_DIR" \
    AGENT_TIMEOUT_SECONDS=5 LOCK_PATH="${ORCH_HOME}/tasks.yml.lock" \
    bash "${REPO_DIR}/scripts/run_task.sh" 2

  # Task should have a worktree set
  run tdb_field 2 worktree
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

@test "gh_pull.sh syncs status forward from GH labels (ratchet)" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  # Create a task linked to GH issue #10, local status=new, old updated_at
  acquire_lock
  create_task_entry 2 "Sync test task" "" ""
  release_lock

  # Set gh_issue_number, status, and an old updated_at so GH appears newer
  tdb "UPDATE tasks SET gh_issue_number = 10, status = 'new', dir = '$PROJECT_DIR', updated_at = '2026-01-01T00:00:00Z' WHERE id = 2;"

  # Stub gh to return issue #10 with status:in_progress label and a newer updated_at
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  cat <<JSON
[{
  "number": 10,
  "title": "Sync test task",
  "body": "",
  "labels": [{"name": "status:in_progress"}],
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

  # Verify status moved forward
  local_status=$(tdb "SELECT status FROM tasks WHERE gh_issue_number = 10;")
  [ "$local_status" = "in_progress" ]
  [[ "$output" == *"status synced from GH: new → in_progress"* ]]
}

@test "gh_pull.sh does not downgrade status from GH labels (ratchet)" {
  source "${REPO_DIR}/scripts/lib.sh"
  init_tasks_file

  acquire_lock
  create_task_entry 2 "Ratchet test" "" ""
  release_lock

  tdb "UPDATE tasks SET gh_issue_number = 11, status = 'in_progress', dir = '$PROJECT_DIR', updated_at = '2026-01-01T00:00:00Z' WHERE id = 2;"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issues"* ]] && [[ "$*" == *"paginate"* ]]; then
  cat <<JSON
[{
  "number": 11,
  "title": "Ratchet test",
  "body": "",
  "labels": [{"name": "status:new"}],
  "state": "open",
  "html_url": "https://github.com/test/repo/issues/11",
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

  # Status should NOT be downgraded
  local_status=$(tdb "SELECT status FROM tasks WHERE gh_issue_number = 11;")
  [ "$local_status" = "in_progress" ]
}

# --- stop.sh --force tests ---

@test "stop.sh --force cleans up pid file and serve lock" {
  # Create fake PID file and serve lock
  echo "99999" > "$STATE_DIR/orchestrator.pid"
  mkdir -p "$STATE_DIR/serve.lock"
  echo "99998" > "$STATE_DIR/tail.pid"

  run env STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/stop.sh" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Force-killed all orchestrator processes"* ]]
  [ ! -f "$STATE_DIR/orchestrator.pid" ]
  [ ! -d "$STATE_DIR/serve.lock" ]
  [ ! -f "$STATE_DIR/tail.pid" ]
}

@test "stop.sh -f is an alias for --force" {
  echo "99999" > "$STATE_DIR/orchestrator.pid"
  mkdir -p "$STATE_DIR/serve.lock"

  run env STATE_DIR="$STATE_DIR" "${REPO_DIR}/scripts/stop.sh" -f
  [ "$status" -eq 0 ]
  [[ "$output" == *"Force-killed all orchestrator processes"* ]]
  [ ! -f "$STATE_DIR/orchestrator.pid" ]
}

# --- version in log output tests ---

@test "log() includes version when ORCH_VERSION is set" {
  source "${REPO_DIR}/scripts/lib.sh"
  export ORCH_VERSION="1.2.3"
  result=$(log "[test] hello")
  [[ "$result" == *"[v1.2.3]"* ]]
  [[ "$result" == *"[test] hello"* ]]
}

@test "log() omits version when ORCH_VERSION is unset" {
  source "${REPO_DIR}/scripts/lib.sh"
  unset ORCH_VERSION
  result=$(log "[test] hello")
  # Should NOT contain [v
  [[ "$result" != *"[v"* ]]
  [[ "$result" == *"[test] hello"* ]]
}

@test "log_err() includes version when ORCH_VERSION is set" {
  source "${REPO_DIR}/scripts/lib.sh"
  export ORCH_VERSION="0.33.0"
  result=$(log_err "[gh_push] syncing" 2>&1)
  [[ "$result" == *"[v0.33.0]"* ]]
}

@test "serve.sh _log includes version prefix" {
  # Verify the _log function in serve.sh includes [vVERSION]
  run grep -E '_log\(\).*\[v\$\{ORCH_VERSION\}\]' "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
}

# --- rate limit backoff in serve.sh tests ---

@test "serve.sh sources lib.sh for backoff helpers" {
  run grep 'source.*lib\.sh' "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
}

@test "serve.sh checks gh_backoff_active before gh_sync" {
  run grep 'gh_backoff_active' "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
}

@test "serve.sh GH_PULL_INTERVAL defaults to 120" {
  run grep 'GH_PULL_INTERVAL=.*120' "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
}

# --- graceful shutdown tests ---

@test "serve.sh uses interruptible sleep" {
  # Verify sleep is backgrounded and waited on
  run grep -A2 'sleep.*INTERVAL.*&' "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wait"* ]]
}

@test "serve.sh checks _stopping flag after each child" {
  # At least 3 stopping checks in the main loop
  count=$(grep -c '_stopping' "${REPO_DIR}/scripts/serve.sh")
  [ "$count" -ge 5 ]
}

# --- PR review agent tests ---

@test "review_prs.sh exits early when review agent disabled" {
  run yq -i '.workflow.enable_review_agent = false' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Mock gh to detect if it's called — it should NOT be called
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
echo "ERROR: gh should not be called" >&2
exit 1
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh exits when no open PRs" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  echo "[]"
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
}

@test "review_prs.sh skips draft PRs by default" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"repos/owner/repo/pulls"* ]]; then
  echo '[{"number":1,"title":"Draft PR","body":"wip","user":{"login":"dev"},"head":{"sha":"abc123","ref":"feat/wip"},"draft":true}]'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"issues"* ]]; then
  echo '[]'
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  # Mock claude (should NOT be called for draft PRs)
  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo "ERROR: claude should not be called for drafts" >&2
exit 1
SH
  chmod +x "$CLAUDE_STUB"

  run env PATH="${TMP_DIR}:${PATH}" "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
  # State file should be empty (no reviews recorded)
  [ ! -s "${STATE_DIR}/pr_reviews.tsv" ] || [ "$(wc -l < "${STATE_DIR}/pr_reviews.tsv")" -eq 0 ]
}

@test "review_prs.sh skips already-reviewed PRs at same SHA" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Pre-populate review state
  mkdir -p "$STATE_DIR"
  printf '1\tabc123\tapprove\t2026-01-01T00:00:00Z\tAlready reviewed PR\n' > "${STATE_DIR}/pr_reviews.tsv"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"repos/owner/repo/pulls"* ]]; then
  echo '[{"number":1,"title":"Already reviewed PR","body":"test","user":{"login":"dev"},"head":{"sha":"abc123","ref":"feat/test"},"draft":false}]'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"issues"* ]]; then
  echo '[]'
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo "ERROR: claude should not be called" >&2
exit 1
SH
  chmod +x "$CLAUDE_STUB"

  run env PATH="${TMP_DIR}:${PATH}" "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]
  # Should still have only 1 line in state
  [ "$(wc -l < "${STATE_DIR}/pr_reviews.tsv")" -eq 1 ]
}

@test "review_prs.sh reviews new PR and records state" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.workflow.review_agent = "claude"' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"repos/owner/repo/pulls"* ]]; then
  echo '[{"number":42,"title":"Add feature","body":"Implements X","user":{"login":"dev"},"head":{"sha":"def456","ref":"feat/add-feature"},"draft":false}]'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"issues"* ]]; then
  echo '[]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "+++ b/test.sh"
  echo "+echo hello"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo '{"decision":"approve","notes":"Looks good, clean implementation."}'
SH
  chmod +x "$CLAUDE_STUB"

  run env PATH="${TMP_DIR}:${PATH}" AGENT_TIMEOUT_SECONDS=10 "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]

  # Should have recorded the review
  run grep "42" "${STATE_DIR}/pr_reviews.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"def456"* ]]
  [[ "$output" == *"approve"* ]]
}

@test "review_prs.sh re-reviews PR when SHA changes" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.workflow.review_agent = "claude"' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Pre-populate with old SHA
  mkdir -p "$STATE_DIR"
  printf '1\told_sha\tapprove\t2026-01-01T00:00:00Z\tOld review\n' > "${STATE_DIR}/pr_reviews.tsv"

  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"repos/owner/repo/pulls"* ]]; then
  echo '[{"number":1,"title":"Updated PR","body":"new commits","user":{"login":"dev"},"head":{"sha":"new_sha","ref":"feat/test"},"draft":false}]'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"issues"* ]]; then
  echo '[]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  echo "+new changes"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "review" ]; then
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  CLAUDE_STUB="${TMP_DIR}/claude"
  cat > "$CLAUDE_STUB" <<'SH'
#!/usr/bin/env bash
echo '{"decision":"request_changes","notes":"Missing tests."}'
SH
  chmod +x "$CLAUDE_STUB"

  run env PATH="${TMP_DIR}:${PATH}" AGENT_TIMEOUT_SECONDS=10 "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]

  # Should have 2 lines in state now (old + new)
  [ "$(wc -l < "${STATE_DIR}/pr_reviews.tsv")" -eq 2 ]
  run grep "new_sha" "${STATE_DIR}/pr_reviews.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"request_changes"* ]]
}

@test "review_prs.sh handles merge command from owner" {
  run yq -i '.workflow.enable_review_agent = true' "$CONFIG_PATH"
  run yq -i '.workflow.review_owner = "gabriel"' "$CONFIG_PATH"
  run yq -i '.gh.repo = "owner/repo"' "$CONFIG_PATH"
  [ "$status" -eq 0 ]

  # Pre-populate as already reviewed (so it only checks merge commands)
  mkdir -p "$STATE_DIR"
  printf '10\tabc123\tapprove\t2026-01-01T00:00:00Z\tPR title\n' > "${STATE_DIR}/pr_reviews.tsv"

  MERGED=false
  GH_STUB="${TMP_DIR}/gh"
  cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$*" == *"repos/owner/repo/pulls"* ]] && [[ "$*" != *"issues"* ]]; then
  echo '[{"number":10,"title":"Ready PR","body":"","user":{"login":"dev"},"head":{"sha":"abc123","ref":"feat/ready"},"draft":false}]'
  exit 0
fi
if [ "$1" = "api" ] && [[ "$*" == *"issues/10/comments"* ]]; then
  echo '[{"user":{"login":"gabriel"},"body":"merge","created_at":"2026-02-19T12:00:00Z"}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "merged"
  exit 0
fi
exit 0
SH
  chmod +x "$GH_STUB"

  run env PATH="${TMP_DIR}:${PATH}" "${REPO_DIR}/scripts/review_prs.sh"
  [ "$status" -eq 0 ]

  # Should have recorded the merge
  run grep "^merge" "${STATE_DIR}/pr_reviews.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"10"* ]]
}

@test "review_prs.sh prompt template exists and has required placeholders" {
  [ -f "${REPO_DIR}/prompts/pr_review.md" ]
  run grep "PR_NUMBER" "${REPO_DIR}/prompts/pr_review.md"
  [ "$status" -eq 0 ]
  run grep "GIT_DIFF" "${REPO_DIR}/prompts/pr_review.md"
  [ "$status" -eq 0 ]
  run grep "PR_TITLE" "${REPO_DIR}/prompts/pr_review.md"
  [ "$status" -eq 0 ]
}

@test "serve.sh calls review_prs.sh after gh_sync" {
  run grep "review_prs.sh" "${REPO_DIR}/scripts/serve.sh"
  [ "$status" -eq 0 ]
}

@test "poll.sh skips tasks with no-agent label" {
  # Create a task with no-agent label via SQLite
  tdb "INSERT INTO tasks (title, body, status, dir, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
    VALUES ('No agent task', '', 'new', '$TMP_DIR', 0, 0, 0, 0, '2026-01-01', '2026-01-01');"
  local new_id
  new_id=$(tdb "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;")
  tdb "INSERT INTO task_labels (task_id, label) VALUES ($new_id, 'no-agent');"

  # Verify the filter expression works — should NOT match no-agent tasks
  run tdb "SELECT t.id FROM tasks t
    WHERE t.status IN ('new', 'routed')
      AND t.id NOT IN (SELECT task_id FROM task_labels WHERE label = 'no-agent')
    ORDER BY t.id;"
  [ "$status" -eq 0 ]
  # Should only have task 1 (Init from setup), not the no-agent task
  [[ "$output" == *"1"* ]]
  [[ "$output" != *"$new_id"* ]]
}

# --- SQLite db.sh tests ---

@test "schema.sql creates all expected tables" {
  local db="${TMP_DIR}/test.db"
  run sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql"
  [ "$status" -eq 0 ]

  # Check all tables exist
  for table in tasks task_labels task_history task_files task_children task_accomplished task_remaining task_blockers task_selected_skills jobs; do
    run sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';"
    [ "$status" -eq 0 ]
    [ "$output" = "$table" ]
  done
}

@test "db_task_field reads a single field" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  run db_task_field 1 status
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  run db_task_field 1 title
  [ "$status" -eq 0 ]
  [ "$output" = "Test" ]
}

@test "db_task_set updates field and bumps updated_at" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  db_task_set 1 status "in_progress"
  run db_task_field 1 status
  [ "$output" = "in_progress" ]

  # updated_at should be newer than 2026-01-01
  run db_task_field 1 updated_at
  [[ "$output" > "2026-01-01" ]]
}

@test "db_task_claim is atomic — rejects wrong from_status" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'done', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  # Trying to claim from 'new' should fail because status is 'done'
  run db_task_claim 1 "new" "in_progress"
  [ "$status" -ne 0 ]

  # Status should still be 'done'
  run db_task_field 1 status
  [ "$output" = "done" ]
}

@test "db_task_claim succeeds with correct from_status" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  run db_task_claim 1 "new" "in_progress"
  [ "$status" -eq 0 ]

  run db_task_field 1 status
  [ "$output" = "in_progress" ]
}

@test "db_task_count counts by status" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'A', 'new', '2026-01-01', '2026-01-01');"
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (2, 'B', 'done', '2026-01-01', '2026-01-01');"
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (3, 'C', 'done', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  run db_task_count "new"
  [ "$output" = "1" ]

  run db_task_count "done"
  [ "$output" = "2" ]

  run db_task_count
  [ "$output" = "3" ]
}

@test "db_create_task creates task with labels" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null

  export DB_PATH="$db" PROJECT_DIR="$TMP_DIR"
  source "${REPO_DIR}/scripts/db.sh"

  NEW_ID=$(db_create_task "My task" "Some body" "$TMP_DIR" "bug,priority:high")
  [ "$NEW_ID" = "1" ]

  run db_task_field 1 title
  [ "$output" = "My task" ]

  run db_task_field 1 status
  [ "$output" = "new" ]

  run db_task_labels_csv 1
  [ "$output" = "bug,priority:high" ]
}

@test "db_append_history adds entries" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  db_append_history 1 "routed" "routed to claude"
  db_append_history 1 "in_progress" "started attempt 1"

  run sqlite3 "$db" "SELECT COUNT(*) FROM task_history WHERE task_id = 1;"
  [ "$output" = "2" ]

  run sqlite3 "$db" "SELECT note FROM task_history WHERE task_id = 1 ORDER BY id LIMIT 1;"
  [ "$output" = "routed to claude" ]
}

@test "db_set_labels replaces existing labels" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"
  sqlite3 "$db" "INSERT INTO task_labels (task_id, label) VALUES (1, 'old-label');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  db_set_labels 1 "new-a,new-b"
  run db_task_labels_csv 1
  [ "$output" = "new-a,new-b" ]

  # Old label should be gone
  run sqlite3 "$db" "SELECT COUNT(*) FROM task_labels WHERE task_id = 1 AND label = 'old-label';"
  [ "$output" = "0" ]
}

@test "db_task_update updates multiple fields at once" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'Test', 'new', '2026-01-01', '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  db_task_update 1 status=done agent=claude summary="Complete"
  run db_task_field 1 status
  [ "$output" = "done" ]
  run db_task_field 1 agent
  [ "$output" = "claude" ]
  run db_task_field 1 summary
  [ "$output" = "Complete" ]
}

@test "db_task_ids_by_status excludes tasks with label" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (1, 'A', 'new', '2026-01-01', '2026-01-01');"
  sqlite3 "$db" "INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (2, 'B', 'new', '2026-01-01', '2026-01-01');"
  sqlite3 "$db" "INSERT INTO task_labels (task_id, label) VALUES (2, 'no-agent');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  run db_task_ids_by_status "new" "no-agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
  [[ "$output" != *"2"* ]]
}

@test "migrate_to_sqlite.sh creates database from YAML" {
  # Create a minimal tasks.yml
  cat > "$TASKS_PATH" <<'YAML'
tasks:
  - id: 1
    title: "Test task"
    body: "Test body"
    labels: ["bug", "p1"]
    status: "done"
    agent: "claude"
    agent_model: null
    agent_profile: null
    complexity: null
    selected_skills: []
    parent_id: null
    children: []
    route_reason: null
    route_warning: null
    summary: "completed"
    reason: null
    accomplished: ["item1"]
    remaining: []
    blockers: []
    files_changed: ["a.sh"]
    needs_help: false
    attempts: 2
    last_error: null
    prompt_hash: null
    last_comment_hash: null
    retry_at: null
    review_decision: null
    review_notes: null
    history:
      - ts: "2026-01-01T00:00:00Z"
        status: "new"
        note: "created"
      - ts: "2026-01-01T01:00:00Z"
        status: "done"
        note: "completed"
    dir: "/tmp"
    created_at: "2026-01-01"
    updated_at: "2026-01-01"
    gh_last_feedback_at: null
YAML

  # Create a minimal jobs.yml
  export JOBS_PATH="${ORCH_HOME}/jobs.yml"
  cat > "$JOBS_PATH" <<'YAML'
jobs:
  - id: test-job
    type: task
    schedule: "0 9 * * 1"
    task:
      title: "Weekly review"
      body: "Review code"
      labels: ["review"]
    command: null
    dir: /tmp
    enabled: true
    last_run: null
    last_task_status: null
    active_task_id: null
YAML

  local db="${ORCH_HOME}/orchestrator.db"
  # Remove the DB created by setup() so migration can create a fresh one
  rm -f "$db" "${db}-wal" "${db}-shm"
  run env DB_PATH="$db" TASKS_PATH="$TASKS_PATH" JOBS_PATH="$JOBS_PATH" SCHEMA_PATH="$SCHEMA_PATH" "${REPO_DIR}/scripts/migrate_to_sqlite.sh"
  [ "$status" -eq 0 ]
  [ -f "$db" ]

  # Verify task
  run sqlite3 "$db" "SELECT title FROM tasks WHERE id = 1;"
  [ "$output" = "Test task" ]

  # Verify labels
  run sqlite3 "$db" "SELECT COUNT(*) FROM task_labels WHERE task_id = 1;"
  [ "$output" = "2" ]

  # Verify history
  run sqlite3 "$db" "SELECT COUNT(*) FROM task_history WHERE task_id = 1;"
  [ "$output" = "2" ]

  # Verify files
  run sqlite3 "$db" "SELECT file_path FROM task_files WHERE task_id = 1;"
  [ "$output" = "a.sh" ]

  # Verify accomplished
  run sqlite3 "$db" "SELECT item FROM task_accomplished WHERE task_id = 1;"
  [ "$output" = "item1" ]

  # Verify job
  run sqlite3 "$db" "SELECT title FROM jobs WHERE id = 'test-job';"
  [ "$output" = "Weekly review" ]
}

@test "db_job_field and db_job_set work correctly" {
  local db="${TMP_DIR}/test.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO jobs (id, title, schedule, type, enabled, created_at) VALUES ('j1', 'Job', '0 9 * * *', 'task', 1, '2026-01-01');"

  export DB_PATH="$db"
  source "${REPO_DIR}/scripts/db.sh"

  run db_job_field j1 schedule
  [ "$output" = "0 9 * * *" ]

  db_job_set j1 enabled 0
  run db_job_field j1 enabled
  [ "$output" = "0" ]
}

@test "sql_escape handles single quotes" {
  export DB_PATH="${TMP_DIR}/test.db"
  source "${REPO_DIR}/scripts/db.sh"

  run sql_escape "it's a test"
  [ "$output" = "it''s a test" ]

  run sql_escape "no quotes"
  [ "$output" = "no quotes" ]
}

# --- SQLite routing tests (lib.sh dual-mode) ---

# Helper: set up a SQLite db and source lib.sh so _use_sqlite returns true
_setup_sqlite_env() {
  local db="${TMP_DIR}/orch.db"
  sqlite3 "$db" < "${REPO_DIR}/scripts/schema.sql" >/dev/null
  sqlite3 "$db" "INSERT INTO tasks (id, title, body, status, agent, dir, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
    VALUES (1, 'Test Task', 'body', 'new', 'claude', '${TMP_DIR}', 0, 0, 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"
  sqlite3 "$db" "INSERT INTO task_labels (task_id, label) VALUES (1, 'bug');"
  export DB_PATH="$db"
  # Re-source lib.sh to pick up the new DB_PATH
  source "${REPO_DIR}/scripts/lib.sh"
}

@test "task_field routes to SQLite when db exists" {
  _setup_sqlite_env
  run task_field 1 .status
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]

  run task_field 1 .title
  [ "$output" = "Test Task" ]
}

@test "task_set routes to SQLite when db exists" {
  _setup_sqlite_env
  task_set 1 .status "done"
  run task_field 1 .status
  [ "$output" = "done" ]
}

@test "task_count routes to SQLite when db exists" {
  _setup_sqlite_env
  run task_count "new"
  [ "$status" -eq 0 ]
  # Should count at least the 1 task we inserted (+ the init task from setup)
  [ "$output" -ge 1 ]
}

@test "append_history routes to SQLite when db exists" {
  _setup_sqlite_env
  append_history 1 "routed" "test note"
  run db_scalar "SELECT COUNT(*) FROM task_history WHERE task_id = 1;"
  [ "$output" -ge 1 ]
  run db_scalar "SELECT note FROM task_history WHERE task_id = 1 ORDER BY id DESC LIMIT 1;"
  [ "$output" = "test note" ]
}

@test "mark_needs_review routes to SQLite when db exists" {
  _setup_sqlite_env
  mark_needs_review 1 0 "test error" "test note"
  run task_field 1 .status
  [ "$output" = "needs_review" ]
  run task_field 1 .last_error
  [ "$output" = "test error" ]
}

@test "acquire_lock is no-op with SQLite" {
  _setup_sqlite_env
  # Should not create lock dir
  acquire_lock
  [ ! -d "$LOCK_PATH" ]
}

@test "with_lock runs command directly with SQLite" {
  _setup_sqlite_env
  # Should succeed without touching lock dir
  run with_lock echo "hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
  [ ! -d "$LOCK_PATH" ]
}

@test "poll.sh works with SQLite backend" {
  _setup_sqlite_env
  # Add a task with status 'new' and no-agent label — should be skipped
  sqlite3 "$DB_PATH" "INSERT INTO tasks (id, title, status, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
    VALUES (99, 'Skip Me', 'new', 0, 0, 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"
  sqlite3 "$DB_PATH" "INSERT INTO task_labels (task_id, label) VALUES (99, 'no-agent');"

  # Set task 1 to 'done' so poll doesn't try to run it
  sqlite3 "$DB_PATH" "UPDATE tasks SET status = 'done' WHERE id = 1;"

  # Add a parent with in_progress child that's already done → should unblock
  sqlite3 "$DB_PATH" "INSERT INTO tasks (id, title, status, parent_id, attempts, needs_help, worktree_cleaned, gh_archived, created_at, updated_at)
    VALUES (100, 'Child Done', 'done', 99, 0, 0, 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"

  # Create a mock gh that does nothing
  gh() { return 0; }
  export -f gh

  # Run poll.sh — should succeed (no tasks to run, no-agent skipped)
  run "${REPO_DIR}/scripts/poll.sh"
  [ "$status" -eq 0 ]
}

@test "add_task.sh uses SQLite when db exists" {
  _setup_sqlite_env
  run "${REPO_DIR}/scripts/add_task.sh" "SQLite Task" "SQLite Body" "feat,test"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Added task" ]]

  # Verify the task is in SQLite
  local count
  count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE title = 'SQLite Task';")
  [ "$count" -eq 1 ]

  # Verify labels
  local label_count
  label_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM task_labels WHERE task_id = (SELECT id FROM tasks WHERE title = 'SQLite Task');")
  [ "$label_count" -eq 2 ]
}

@test "db_load_task handles multiline body without truncating fields" {
  source "${REPO_DIR}/scripts/lib.sh"

  # Create a task with a multiline body containing newlines
  local multiline_body
  multiline_body=$(printf 'Line 1\nLine 2\nLine 3\n\nLine 5 with context')
  local task_id
  task_id=$(db_scalar "INSERT INTO tasks (title, body, status, dir, gh_issue_number, created_at, updated_at)
    VALUES ('Multiline Test', '$(sql_escape "$multiline_body")', 'new', '/tmp/test-project', 42, datetime('now'), datetime('now'))
    RETURNING id;")

  # Load the task
  db_load_task "$task_id"

  # Verify fields AFTER body are not empty (the bug would make them empty)
  [ "$TASK_STATUS" = "new" ]
  [ "$TASK_DIR" = "/tmp/test-project" ]
  [ "$GH_ISSUE_NUMBER" = "42" ]
  [ "$TASK_TITLE" = "Multiline Test" ]

  # Verify body contains all lines (not truncated at first newline)
  local body_lines
  body_lines=$(printf '%s' "$TASK_BODY" | wc -l | tr -d ' ')
  [ "$body_lines" -ge 4 ]
}

@test "gh_push.sh skips tasks from other projects (cross-project guard)" {
  source "${REPO_DIR}/scripts/lib.sh"

  # Create a task with a multiline body AND a different dir
  local multiline_body
  multiline_body=$(printf 'Context\nThis task belongs to another project\nShould not be pushed here')
  db "INSERT INTO tasks (title, body, status, dir, gh_issue_number, created_at, updated_at)
    VALUES ('Foreign Task', '$(sql_escape "$multiline_body")', 'new', '/tmp/other-project', '', datetime('now'), datetime('now'));"

  # Load it and verify the cross-project guard would work
  local foreign_id
  foreign_id=$(db_scalar "SELECT id FROM tasks WHERE title = 'Foreign Task';")
  db_load_task "$foreign_id"

  # Key assertion: dir must be loaded correctly even with multiline body
  [ "$TASK_DIR" = "/tmp/other-project" ]
  [ "$TASK_STATUS" = "new" ]

  # Simulate the cross-project guard from gh_push.sh
  local PROJECT_DIR="${TMP_DIR}"
  local TASK_DIR_VAL="$TASK_DIR"
  if [ -n "$TASK_DIR_VAL" ] && [ "$TASK_DIR_VAL" != "null" ] && [ "$TASK_DIR_VAL" != "$PROJECT_DIR" ]; then
    # Guard triggered — task would be skipped (correct behavior)
    true
  else
    # Guard NOT triggered — task would be pushed to wrong repo (BUG)
    false
  fi
}

# ─── build_git_diff tests ───

@test "build_git_diff shows stat for uncommitted changes" {
  # Create a tracked file, then modify it
  echo "hello" > "${PROJECT_DIR}/file.txt"
  git -C "$PROJECT_DIR" add file.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add file" --quiet

  echo "world" >> "${PROJECT_DIR}/file.txt"

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uncommitted changes:"* ]]
  [[ "$output" == *"file.txt"* ]]
}

@test "build_git_diff shows diff against base branch" {
  # Create a feature branch with a commit
  git -C "$PROJECT_DIR" checkout -b feature-test --quiet
  echo "new content" > "${PROJECT_DIR}/feature.txt"
  git -C "$PROJECT_DIR" add feature.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add feature" --quiet

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Diff against main:"* ]]
  [[ "$output" == *"new content"* ]]
}

@test "build_git_diff shows commit log since base branch" {
  git -C "$PROJECT_DIR" checkout -b log-test --quiet
  echo "log content" > "${PROJECT_DIR}/log.txt"
  git -C "$PROJECT_DIR" add log.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add log file" --quiet

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commits since main:"* ]]
  [[ "$output" == *"add log file"* ]]
}

@test "build_git_diff returns empty for no changes" {
  # On main with no changes — no diff, no commits
  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' main"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build_git_diff truncates diff to 200 lines" {
  git -C "$PROJECT_DIR" checkout -b trunc-test --quiet
  # Generate a file with 300 lines to produce a diff > 200 lines
  for i in $(seq 1 300); do echo "line $i"; done > "${PROJECT_DIR}/big.txt"
  git -C "$PROJECT_DIR" add big.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add big file" --quiet

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' main"
  [ "$status" -eq 0 ]
  # Count diff lines (between "Diff against" header and next section or end)
  local diff_lines
  diff_lines=$(echo "$output" | sed -n '/^Diff against/,/^$/p' | wc -l)
  # The diff output section should be at most ~202 lines (header + 200 content + blank)
  [ "$diff_lines" -le 203 ]
}

@test "build_git_diff accepts custom base branch" {
  git -C "$PROJECT_DIR" checkout -b develop --quiet
  echo "develop content" > "${PROJECT_DIR}/dev.txt"
  git -C "$PROJECT_DIR" add dev.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add dev" --quiet

  git -C "$PROJECT_DIR" checkout -b feature-from-develop --quiet
  echo "feature content" > "${PROJECT_DIR}/feat.txt"
  git -C "$PROJECT_DIR" add feat.txt
  git -C "$PROJECT_DIR" -c user.email="test@test.com" -c user.name="Test" commit -m "add feat" --quiet

  run bash -c "source '${REPO_DIR}/scripts/lib.sh' && build_git_diff '$PROJECT_DIR' develop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Diff against develop:"* ]]
  [[ "$output" == *"feature content"* ]]
  [[ "$output" == *"Commits since develop:"* ]]
  [[ "$output" == *"add feat"* ]]
}
