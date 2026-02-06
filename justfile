set shell := ["bash", "-c"]

default:
  @just --list

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
  @scripts/add_task.sh "{{title}}" "{{body}}" "{{labels}}"

# Route a task (choose agent/profile/skills)
route id="":
  @scripts/route_task.sh {{id}}

# Run a task (routes first if needed)
run id="":
  @scripts/run_task.sh {{id}}

# Force a task to use a specific agent
set-agent id agent:
  @scripts/set_agent.sh {{id}} {{agent}}

# Route+run the next task in one step
next:
  @scripts/next.sh

# Run all runnable tasks in parallel
poll jobs="4":
  @POLL_JOBS={{jobs}} scripts/poll.sh

# Re-run blocked parents when children done
rejoin jobs="4":
  @POLL_JOBS={{jobs}} scripts/rejoin.sh

# Loop poll every interval seconds
watch interval="10":
  @scripts/watch.sh {{interval}}

# Start server (poll + gh sync) and auto-restart
# on config or code changes
serve interval="10":
  @INTERVAL={{interval}} TAIL_LOG=1 scripts/serve.sh

# Stop the server if running
stop:
  @scripts/stop.sh

# Restart the server
restart:
  @scripts/restart.sh

# Remove stale task locks
unlock:
  @scripts/unlock.sh

# Tail orchestrator.log
log tail="50":
  @tail -n {{tail}} orchestrator.log

# Install to ~/.orchestrator and add wrapper to ~/.bin
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

# List GitHub Projects for an org or user
gh-project-list org="" user="":
  @scripts/gh_project_list.sh "{{org}}" "{{user}}"

# Run tests
# (bats test suite)
test:
  @bats tests
