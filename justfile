set shell := ["bash", "-c"]

_default:
    @just --list

# Show orchestrator version
version:
    @echo "${ORCH_VERSION:-$(git describe --tags --always 2>/dev/null || echo unknown)}"

# Initialize orchestrator for current project
init *args="":
    @scripts/init.sh {{ args }}

# Interactive chat with the orchestrator
chat:
    @scripts/chat.sh

# Overview: tasks, projects, worktrees
dashboard:
    @scripts/dashboard.sh

# Tail orchestrator.log (checks service log, then state dir)
log tail="50":
    @if [ -f "${HOMEBREW_PREFIX:-/opt/homebrew}/var/log/orchestrator.log" ]; then \
      tail -n {{ tail }} "${HOMEBREW_PREFIX:-/opt/homebrew}/var/log/orchestrator.log"; \
    else \
      tail -n {{ tail }} "${STATE_DIR:-.orchestrator}/orchestrator.log"; \
    fi

# List installed agent CLIs
agents:
    @scripts/agents.sh


# --- Namespace: task (list, tree, add, plan, route, run, next, poll, retry, unblock, agent, stream, rejoin, watch, unlock) ---

# Manage tasks (status, list, tree, add, plan, route, run, next, poll, retry, unblock, agent, stream, watch, unlock)
task target *args:
    @just _task_{{ target }} {{ args }}

[private]
_task_status *args:
    @scripts/status.sh {{ args }}

[private]
_task_list:
    @scripts/list_tasks.sh

[private]
_task_tree:
    @scripts/tree.sh

[private]
_task_add *args:
    @scripts/add_task.sh {{ args }}

[private]
_task_plan *args:
    #!/usr/bin/env bash
    # Extract title, body, labels from args
    TITLE="${1:-}" BODY="${2:-}" LABELS="${3:-}"
    if [ "${PLAN_INTERACTIVE:-1}" = "0" ]; then
      scripts/add_task.sh "$TITLE" "$BODY" "plan,$LABELS"
    else
      scripts/plan_chat.sh "$TITLE" "$BODY" "$LABELS"
    fi

[private]
_task_route id="":
    @scripts/route_task.sh {{ id }}

[private]
_task_run id="":
    @scripts/run_task.sh {{ id }}

[private]
_task_next:
    @scripts/next.sh

[private]
_task_poll *args:
    @POLL_JOBS={{ if args == "" { "4" } else { args } }} scripts/poll.sh

[private]
_task_retry id:
    @scripts/retry_task.sh {{ id }}

[private]
_task_unblock *args:
    #!/usr/bin/env bash
    if [ "${1:-}" = "all" ]; then
      yq -r '.tasks[] | select(.status == "blocked") | .id' "${TASKS_PATH:-tasks.yml}" | xargs -n1 scripts/retry_task.sh
    else
      scripts/retry_task.sh "${1:?Usage: orchestrator task unblock <id|all>}"
    fi

[private]
_task_agent id agent:
    @scripts/set_agent.sh {{ id }} {{ agent }}

[private]
_task_stream id:
    @scripts/stream_task.sh {{ id }}

[private]
_task_rejoin *args:
    @POLL_JOBS={{ if args == "" { "4" } else { args } }} scripts/rejoin.sh

[private]
_task_watch *args:
    @scripts/watch.sh {{ if args == "" { "10" } else { args } }}

[private]
_task_unlock:
    @scripts/unlock.sh

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

# --- Namespace: gh (pull, push, sync) ---

# GitHub sync (pull, push, sync)
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

# --- Namespace: project (info, create, list) ---

# GitHub Projects V2 (info, create, list)
project target *args:
    @just _project_{{ target }} {{ args }}

[private]
_project_info *args:
    @scripts/gh_project_info.sh {{ args }}

[private]
_project_create title="":
    @scripts/gh_project_create.sh "{{ title }}"

[private]
_project_list org="" user="":
    @scripts/gh_project_list.sh "{{ org }}" "{{ user }}"

# --- Namespace: job (add, list, remove, enable, disable, tick) ---

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

# --- Namespace: skills (list, sync) ---

# Manage skills registry (list, sync)
skills target *args:
    @just _skills_{{ target }} {{ args }}

[private]
_skills_list:
    @scripts/skills_list.sh

[private]
_skills_sync:
    @scripts/skills_sync.sh

# --- Backward-compatible aliases (hidden) ---

[private]
status *args:
    @just task status {{ args }}

[private]
list:
    @just task list

[private]
tree:
    @just task tree

[private]
add title body="" labels="":
    @just task add "{{ title }}" "{{ body }}" "{{ labels }}"

[private]
plan title body="" labels="":
    @just task plan "{{ title }}" "{{ body }}" "{{ labels }}"

[private]
route id="":
    @just task route {{ id }}

[private]
run id="":
    @just task run {{ id }}

[private]
next:
    @just task next

[private]
poll jobs="4":
    @just task poll {{ jobs }}

[private]
retry id:
    @just task retry {{ id }}

[private]
unblock id:
    @just task unblock {{ id }}

[private]
unblock-all:
    @just task unblock all

[private]
set-agent id agent:
    @just task agent {{ id }} {{ agent }}

[private]
rejoin jobs="4":
    @just task rejoin {{ jobs }}

[private]
watch interval="10":
    @just task watch {{ interval }}

[private]
stream id:
    @just task stream {{ id }}

[private]
unlock:
    @just task unlock

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

[private]
gh-pull:
    @just gh pull

[private]
gh-push:
    @just gh push

[private]
gh-sync:
    @just gh sync

[private]
gh-project-info *args:
    @just project info {{ args }}

[private]
gh-project-create title="":
    @just project create "{{ title }}"

[private]
gh-project-list *args:
    @just project list {{ args }}

[private]
gh-project-info-fix:
    @just project info --fix

[private]
jobs-add *args:
    @just job add {{ args }}

[private]
jobs-list:
    @just job list

[private]
jobs-remove id:
    @just job remove {{ id }}

[private]
jobs-enable id:
    @just job enable {{ id }}

[private]
jobs-disable id:
    @just job disable {{ id }}

[private]
jobs-tick:
    @just job tick

[private]
skills-sync:
    @just skills sync

[private]
service-install:
    @just service install

[private]
service-uninstall:
    @just service uninstall

# Run tests (bats test suite)
[private]
test:
    @bats tests
