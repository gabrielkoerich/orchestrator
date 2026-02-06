#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  TMP_DIR=$(mktemp -d)
  export TASKS_PATH="${TMP_DIR}/tasks.yml"

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
cat <<'YAML'
executor: codex
reason: "test route"
profile:
  role: "backend specialist"
  skills: ["api", "sql"]
  tools: ["git", "rg"]
  constraints: ["no migrations"]
YAML
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run "${REPO_DIR}/scripts/route_task.sh" 2
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

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

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'YAML'
status: in_progress
summary: "scoped work"
files_changed: []
needs_help: true
delegations:
  - title: "Child Task"
    body: "Do subtask"
    labels: ["sub"]
    suggested_agent: "codex"
YAML
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run yq -i '.tasks[] | select(.id == 2) | .agent = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  run "${REPO_DIR}/scripts/run_task.sh" 2
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

  run yq -i '.tasks[] | select(.id == 2) | .status = "blocked" | .children = [3]' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  run yq -i '.tasks[] | select(.id == 3) | .status = "done" | .agent = "codex"' "$TASKS_PATH"
  [ "$status" -eq 0 ]

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'YAML'
status: done
summary: "ok"
files_changed: []
needs_help: false
delegations: []
YAML
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run "${REPO_DIR}/scripts/poll.sh"
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .status' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}
