set shell := ["bash", "-c"]

_default:
    @just --list

# Show orchestrator version
version:
    @echo "${ORCH_VERSION:-$(git describe --tags --always 2>/dev/null || echo unknown)}"

# List all tasks (id, status, agent, parent, title)
list:
    @scripts/list_tasks.sh

# Show status counts and recent tasks
status:
    @scripts/status.sh

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

# Start server (poll + gh sync) and auto-restart on config or code changes
serve interval="10":
    @INTERVAL={{ interval }} TAIL_LOG=1 scripts/serve.sh

# Alias for serve
start interval="10":
    @just serve {{ interval }}

# Stop the server if running
stop:
    @scripts/stop.sh

# Restart the server
restart:
    @scripts/restart.sh

# Show service info and status
info:
    #!/usr/bin/env bash
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

# Install to ~/.orchestrator and add wrapper to ~/.bin
[private]
install:
    @scripts/setup.sh

# Sync skills registry repositories into ./skills
skills-sync:
    @scripts/skills_sync.sh

# Pull tasks from GitHub issues into tasks.yml
gh-pull:
    @scripts/gh_pull.sh

# Push task updates to GitHub issues
gh-push:
    @scripts/gh_push.sh

# Pull then push GitHub sync in one step
gh-sync:
    @scripts/gh_sync.sh

# Show GitHub Project field and option ids
gh-project-info:
    @scripts/gh_project_info.sh

# Auto-apply Status field/option IDs to config.yml
gh-project-info-fix:
    @scripts/gh_project_info.sh --fix

# Create a new GitHub Project for the current repo
gh-project-create title="":
    @scripts/gh_project_create.sh "{{ title }}"

# List GitHub Projects for an org or user
gh-project-list org="" user="":
    @scripts/gh_project_list.sh "{{ org }}" "{{ user }}"

# Add a scheduled job (cron expression + task template)
jobs-add schedule title body="" labels="" agent="":
    @scripts/jobs_add.sh "{{ schedule }}" "{{ title }}" "{{ body }}" "{{ labels }}" "{{ agent }}"

# List all scheduled jobs
jobs-list:
    @scripts/jobs_list.sh

# Remove a scheduled job
jobs-remove id:
    @scripts/jobs_remove.sh "{{ id }}"

# Enable a scheduled job
jobs-enable id:
    @yq -i '(.jobs[] | select(.id == "{{ id }}") | .enabled) = true' "${JOBS_PATH:-jobs.yml}" && echo "Enabled job '{{ id }}'"

# Disable a scheduled job
jobs-disable id:
    @yq -i '(.jobs[] | select(.id == "{{ id }}") | .enabled) = false' "${JOBS_PATH:-jobs.yml}" && echo "Disabled job '{{ id }}'"

# Check and run due scheduled jobs
jobs-tick:
    @scripts/jobs_tick.sh

# Install crontab entry to tick every minute
jobs-install:
    @scripts/jobs_install.sh

# Remove crontab entry
jobs-uninstall:
    @scripts/jobs_uninstall.sh

# Install macOS launchd service (auto-start + restart on crash)
service-install:
    @scripts/service_install.sh

# Uninstall macOS launchd service
service-uninstall:
    @scripts/service_uninstall.sh

# Run tests (bats test suite)
[private]
test:
    @bats tests
