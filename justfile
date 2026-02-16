set shell := ["bash", "-c"]

_default:
    @just --list

# Show orchestrator version
[group('config')]
version:
    @echo "${ORCH_VERSION:-$(git describe --tags --always 2>/dev/null || echo unknown)}"

# Initialize orchestrator for current project
[group('config')]
init *args="":
    @scripts/init.sh {{ args }}

# Interactive chat with the orchestrator
[group('agents')]
chat:
    @scripts/chat.sh

# Overview: tasks, projects, worktrees
[group('agents')]
dashboard:
    @scripts/dashboard.sh

# Tail orchestrator logs (server + errors)
[group('config')]
log tail="50":
    #!/usr/bin/env bash
    STATE="${STATE_DIR:-.orchestrator}"
    BREW_LOG="${HOMEBREW_PREFIX:-/opt/homebrew}/var/log/orchestrator.log"
    # Show error log if it exists
    if [ -f "$STATE/orchestrator.error.log" ] && [ -s "$STATE/orchestrator.error.log" ]; then
      echo "=== Error Log ==="
      tail -n {{ tail }} "$STATE/orchestrator.error.log"
      echo ""
    fi
    echo "=== Server Log ==="
    if [ -f "$BREW_LOG" ]; then
      tail -n {{ tail }} "$BREW_LOG"
    elif [ -f "$STATE/orchestrator.log" ]; then
      tail -n {{ tail }} "$STATE/orchestrator.log"
    else
      echo "(no log file found)"
    fi

#################################
# Namespace: skills (list, sync)
#################################

# Manage skills registry (list, sync)
[group('agents')]
skills target *args:
    @just _skills_{{ target }} {{ args }}

[private]
_skills_list:
    @scripts/skills_list.sh

[private]
_skills_sync:
    @scripts/skills_sync.sh

# List installed agent CLIs
[group('agents')]
agents:
    @scripts/agents.sh

########################################################################################################
# Namespace: task (list, tree, add, plan, route, run, next, poll, retry, unblock, agent, stream, rejoin, watch, unlock)
########################################################################################################

# Manage tasks (status, list, tree, add, plan, route, run, next, poll, retry, unblock, agent, stream, watch, unlock)
[group('tasks/jobs')]
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

# Set PLAN_INTERACTIVE=0 to skip interactive planning and just add task with plan label
[private]
_task_plan title body="" labels="":
    {{ if env("PLAN_INTERACTIVE", "1") == "0" { "scripts/add_task.sh \"" + title + "\" \"" + body + "\" \"plan," + labels + "\"" } else { "scripts/plan_chat.sh \"" + title + "\" \"" + body + "\" \"" + labels + "\"" } }}

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
_task_unblock id:
    {{ if id == "all" { "yq -r '.tasks[] | select(.status == \"blocked\") | .id' \"${TASKS_PATH:-tasks.yml}\" | xargs -n1 scripts/retry_task.sh" } else { "scripts/retry_task.sh " + id } }}

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

#####################################################################
# Namespace: service (start, stop, restart, info, install, uninstall)
#####################################################################

# Manage the orchestrator service (start, stop, restart, info, install, uninstall)
[group('service')]
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

##################################
# Namespace: gh (pull, push, sync)
##################################

# GitHub sync (pull, push, sync)
[group('github')]
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

#########################################
# Namespace: project (info, create, list)
#########################################

# GitHub Projects V2 (info, create, list)
[group('github')]
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

###########################################################
# Namespace: job (add, list, remove, enable, disable, tick)
###########################################################

# Manage scheduled jobs (add, list, remove, enable, disable, tick)
[group('tasks/jobs')]
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

############################
#  Brew services commands
#############################

# Stop orchestrator service (via brew)
[group('service')]
stop:
    @just service stop

# Restar orchestrator service (via brew)
[group('service')]
start:
    @just service restart

# Restar orchestrator service (via brew)
[group('service')]
restart:
    @just service restart

[private]
info:
    @just service info

[private]
serve interval="10":
    @just _service_serve {{ interval }}

# Run tests (bats test suite)
[private]
test:
    @bats tests

############################
#  Legacy manual & Services
############################

[private]
install:
    @scripts/setup.sh

[private]
service-install:
    @just service install

[private]
service-uninstall:
    @just service uninstall
