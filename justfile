set shell := ["bash", "-c"]

default:
  @just --list

list:
  @scripts/list_tasks.sh

add title body labels="":
  @scripts/add_task.sh "{{title}}" "{{body}}" "{{labels}}"

route id:
  @scripts/route_task.sh {{id}}

run id:
  @scripts/run_task.sh {{id}}

test:
  @bats tests
