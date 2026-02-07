#!/usr/bin/env bats

setup() {
  export REPO_DIR="${BATS_TEST_DIRNAME}/.."
  export PATH="${REPO_DIR}/scripts:${PATH}"

  TMP_DIR=$(mktemp -d)
  export STATE_DIR="${TMP_DIR}/.orchestrator"
  mkdir -p "$STATE_DIR"
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

  CODEX_STUB="${TMP_DIR}/codex"
  cat > "$CODEX_STUB" <<'SH'
#!/usr/bin/env bash
prompt="$*"
if printf '%s' "$prompt" | rg -q "reviewing agent"; then
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

  run env PATH="${TMP_DIR}:${PATH}" TASKS_PATH="$TASKS_PATH" CONFIG_PATH="$CONFIG_PATH" "${REPO_DIR}/scripts/run_task.sh" 2
  [ "$status" -eq 0 ]

  run yq -r '.tasks[] | select(.id == 2) | .review_decision' "$TASKS_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "approve" ]
}
