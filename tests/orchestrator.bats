#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  TMP_DIR=$(mktemp -d)
  export TASKS_PATH="${TMP_DIR}/tasks.yml"
  export CONFIG_PATH="${TMP_DIR}/config.yml"
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

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/run_task.sh" 2
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

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"ok","files_changed":[],"needs_help":false,"delegations":[]}
JSON
SH
  chmod +x "$CODEX_STUB"
  export PATH="${TMP_DIR}:${PATH}"

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/poll.sh"
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
  run bash -c "source '${REPO_DIR}/scripts/lib.sh'; RAW=\$(cat '$RAW_FILE'); normalize_json_response \"\$RAW\" | jq -r '.executor'"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}
