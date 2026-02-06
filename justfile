set shell := ["bash", "-c"]

default:
  @just --list

list:
  @scripts/list_tasks.sh

status:
  @scripts/status.sh

tree:
  @scripts/tree.sh

add title body labels="":
  @scripts/add_task.sh "{{title}}" "{{body}}" "{{labels}}"

route id:
  @scripts/route_task.sh {{id}}

run id:
  @scripts/run_task.sh {{id}}

poll jobs="4":
  @POLL_JOBS={{jobs}} scripts/poll.sh

rejoin jobs="4":
  @POLL_JOBS={{jobs}} scripts/rejoin.sh

watch interval="10":
  @scripts/watch.sh {{interval}}

gh-pull:
  @scripts/gh_pull.sh

gh-push:
  @scripts/gh_push.sh

gh-sync:
  @scripts/gh_sync.sh

test:
  @bats tests
