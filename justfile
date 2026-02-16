set shell := ["bash", "-c"]

_default:
    @just --list

# Show orchestrator version
version:
    @echo "${ORCH_VERSION:-$(git describe --tags --always 2>/dev/null || echo unknown)}"

# List all tasks (id, status, agent, parent, title)
list:
    @scripts/list_tasks.sh

# Show status counts and recent tasks (-g for global across projects)
status *args:
    @scripts/status.sh {{ args }}

# Show status counts and grouped tasks by status
dashboard:
    @scripts/dashboard.sh

# Show task tree with parent/child hierarchy
tree:
    @scripts/tree.sh

# Add a task (title required, body/labels optional)
add title body="" labels="":
    @scripts/add_task.sh "{{ title }}" "{{ body }}" "{{ labels }}"

# Interactively plan and decompose a goal into subtasks
plan title body="" labels="":
    #!/usr/bin/env bash
    if [ "${PLAN_INTERACTIVE:-1}" = "0" ]; then
      scripts/add_task.sh "{{ title }}" "{{ body }}" "plan,{{ labels }}"
    else
      scripts/plan_chat.sh "{{ title }}" "{{ body }}" "{{ labels }}"
    fi

# Route a task (choose agent/profile/skills)
route id="":
    @scripts/route_task.sh {{ id }}

# Run a task (routes first if needed)
run id="":
    @scripts/run_task.sh {{ id }}

# Retry a blocked/done/failed task (reset to new)
retry id:
    @scripts/retry_task.sh {{ id }}

# Unblock a blocked task (reset to new)
unblock id:
    @scripts/retry_task.sh {{ id }}

# Unblock all blocked tasks (reset to new)
unblock-all:
    @yq -r '.tasks[] | select(.status == "blocked") | .id' "${TASKS_PATH:-tasks.yml}" | xargs -n1 scripts/retry_task.sh

# Force a task to use a specific agent
set-agent id agent:
    @scripts/set_agent.sh {{ id }} {{ agent }}

# Route+run the next task in one step
next:
    @scripts/next.sh

# Run all runnable tasks in parallel
poll jobs="4":
    @POLL_JOBS={{ jobs }} scripts/poll.sh

# Re-run blocked parents when children done
rejoin jobs="4":
    @POLL_JOBS={{ jobs }} scripts/rejoin.sh

# Loop poll every interval seconds
watch interval="10":
    @scripts/watch.sh {{ interval }}

# Stream live agent output for a task
stream id:
    @scripts/stream_task.sh {{ id }}

# Remove stale task locks
unlock:
    @scripts/unlock.sh

# Tail orchestrator.log (checks service log, then state dir)
log tail="50":
    @if [ -f "${HOMEBREW_PREFIX:-/opt/homebrew}/var/log/orchestrator.log" ]; then \
      tail -n {{ tail }} "${HOMEBREW_PREFIX:-/opt/homebrew}/var/log/orchestrator.log"; \
    else \
      tail -n {{ tail }} "${STATE_DIR:-.orchestrator}/orchestrator.log"; \
    fi

# Initialize orchestrator for current project
init *args="":
    @scripts/init.sh {{ args }}

# Interactive chat with the orchestrator
chat:
    @scripts/chat.sh

# List installed agent CLIs
agents:
    @scripts/agents.sh

# List all projects with tasks
projects:
    @yq -r '[.tasks[].dir // ""] | unique | map(select(length > 0)) | .[]' "${TASKS_PATH:-tasks.yml}"

# Sync skills registry repositories into ./skills
skills-sync:
    @scripts/skills_sync.sh

# --- Namespace: service (start, stop, restart, info, install, uninstall) ---

# Manage the orchestrator service (start, stop, restart, info, install, uninstall)
service target *args:
    @just _service_{{ target }} {{ args }}

[private]
_service_start interval="10":
    #!/usr/bin/env bash
    if [ "${ORCH_BREW:-}" = "1" ]; then
      brew services start orchestrator
    else
      INTERVAL={{ interval }} TAIL_LOG=1 exec scripts/serve.sh
    fi

# Run server directly (used by brew services internally)
[private]
_service_serve interval="10":
    @INTERVAL={{ interval }} scripts/serve.sh

[private]
_service_stop:
    #!/usr/bin/env bash
    if [ "${ORCH_BREW:-}" = "1" ]; then
      brew services stop orchestrator
    else
      scripts/stop.sh
    fi

[private]
_service_restart:
    #!/usr/bin/env bash
    if [ "${ORCH_BREW:-}" = "1" ]; then
      brew services restart orchestrator
    else
      scripts/restart.sh
    fi

[private]
_service_info:
    #!/usr/bin/env bash
    if [ "${ORCH_BREW:-}" = "1" ]; then
      brew services info orchestrator
    else
      PID_FILE="${STATE_DIR:-.orchestrator}/orchestrator.pid"
      if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
          echo "Orchestrator running (pid $PID)"
        else
          echo "Orchestrator not running (stale pid $PID)"
        fi
      else
        echo "Orchestrator not running (no pid file)"
      fi
    fi

[private]
_service_install:
    @scripts/service_install.sh

[private]
_service_uninstall:
    @scripts/service_uninstall.sh

# --- Namespace: gh (pull, push, sync, project) ---

# GitHub integration (pull, push, sync, project-info, project-create, project-list)
gh target *args:
    @just _gh_{{ target }} {{ args }}

[private]
_gh_pull:
    @scripts/gh_pull.sh

[private]
_gh_push:
    @scripts/gh_push.sh

[private]
_gh_sync:
    @scripts/gh_sync.sh

[private]
_gh_project-info *args:
    @scripts/gh_project_info.sh {{ args }}

[private]
_gh_project-create title="":
    @scripts/gh_project_create.sh "{{ title }}"

[private]
_gh_project-list org="" user="":
    @scripts/gh_project_list.sh "{{ org }}" "{{ user }}"

# --- Namespace: job (add, list, remove, enable, disable, tick, install, uninstall) ---

# Manage scheduled jobs (add, list, remove, enable, disable, tick)
job target *args:
    @just _job_{{ target }} {{ args }}

[private]
_job_add *args:
    @scripts/jobs_add.sh {{ args }}

[private]
_job_list:
    @scripts/jobs_list.sh

[private]
_job_remove id:
    @scripts/jobs_remove.sh "{{ id }}"

[private]
_job_enable id:
    @yq -i '(.jobs[] | select(.id == "{{ id }}") | .enabled) = true' "${JOBS_PATH:-jobs.yml}" && echo "Enabled job '{{ id }}'"

[private]
_job_disable id:
    @yq -i '(.jobs[] | select(.id == "{{ id }}") | .enabled) = false' "${JOBS_PATH:-jobs.yml}" && echo "Disabled job '{{ id }}'"

[private]
_job_tick:
    @scripts/jobs_tick.sh

[private]
_job_install:
    @scripts/jobs_install.sh

[private]
_job_uninstall:
    @scripts/jobs_uninstall.sh

# --- Backward-compatible aliases (hidden) ---

[private]
start interval="10":
    @just service start {{ interval }}

[private]
stop:
    @just service stop

[private]
restart:
    @just service restart

[private]
info:
    @just service info

[private]
serve interval="10":
    @just _service_serve {{ interval }}

[private]
install:
    @scripts/setup.sh

# Run tests (bats test suite)
[private]
test:
    @bats tests
