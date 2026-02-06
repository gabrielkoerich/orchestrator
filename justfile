set shell := ["bash", "-c"]

default:
  @just --list

list:
  @scripts/list_tasks.sh

status:
  @scripts/status.sh

dashboard:
  @scripts/dashboard.sh

tree:
  @scripts/tree.sh

add title body="" labels="":
  @scripts/add_task.sh "{{title}}" "{{body}}" "{{labels}}"

route id="":
  @scripts/route_task.sh {{id}}

run id="":
  @scripts/run_task.sh {{id}}

set-agent id agent:
  @scripts/set_agent.sh {{id}} {{agent}}

next:
  @scripts/next.sh

poll jobs="4":
  @POLL_JOBS={{jobs}} scripts/poll.sh

rejoin jobs="4":
  @POLL_JOBS={{jobs}} scripts/rejoin.sh

watch interval="10":
  @scripts/watch.sh {{interval}}

serve interval="10":
  @INTERVAL={{interval}} scripts/serve.sh

log tail="50":
  @tail -n {{tail}} orchestrator.log

setup:
  @scripts/setup.sh

skills-sync:
  @scripts/skills_sync.sh

gh-pull:
  @scripts/gh_pull.sh

gh-push:
  @scripts/gh_push.sh

gh-sync:
  @scripts/gh_sync.sh

test:
  @bats tests
