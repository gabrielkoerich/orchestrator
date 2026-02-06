# Agent Orchestrator (bash, YAML + yq)

A lightweight autonomous agent orchestrator that routes tasks, spawns specialized agent profiles, and supports delegation. Tasks live in `tasks.yml` (source of truth). Agents run via CLI tools (`codex` and `claude`) and can delegate subtasks dynamically.

## Requirements
- `yq` (mikefarah)
- `just`
- Agent CLIs in your PATH:
  - `codex`
  - `claude`
- Optional: `gh` for GitHub sync

## Files
- `tasks.yml` — task database (YAML)
- `prompts/route.md` — routing + profile generation prompt
- `prompts/agent.md` — execution prompt (includes profile)
- `scripts/*.sh` — orchestration commands
- `tests/orchestrator.bats` — tests

## Task Model
Each task includes:
- `id`, `title`, `body`, `labels`
- `status`: `new`, `routed`, `in_progress`, `done`, `blocked`, `needs_review`
- `agent`: executor (`codex` or `claude`)
- `agent_profile`: dynamically generated role/skills/tools/constraints
- `parent_id`, `children` for delegation
- `summary`, `files_changed`, `needs_help`

GitHub metadata fields (optional):
- `gh_issue_number`, `gh_url`, `gh_state`, `gh_updated_at`, `gh_synced_at`

## How It Works
1. **Add a task** to `tasks.yml` (or via `just add`).
2. **Route the task** with an LLM that chooses executor + builds a specialized profile.
3. **Run the task** with the chosen executor and profile.
4. **Delegation**: if the agent returns `delegations`, child tasks are created and the parent is blocked until children finish.
5. **Rejoin**: parent resumes when children are done.

## Usage

### Add a task
```
just add "Build router" "Add LLM router and task runner" "orchestration,router"
```

### List tasks
```
just list
```

### Status dashboard
```
just status
```

### Task tree
```
just tree
```

### Route a task
```
just route 1
```
If no ID is provided, the next `new` task is routed.

### Run a task
```
just run 1
```
If no ID is provided, the next `new` task is run (or `routed` if no `new`).

### Poll all tasks (parallel)
```
just poll
just poll 8
```

### Rejoin blocked parents (parallel)
```
just rejoin
```

### Watch loop
```
just watch
just watch 5
```

### Tests
```
just test
```

## Dynamic Agent Profiles
The router generates a profile for each task, persisted in `tasks.yml`. You can edit it manually if the agent needs refinement.

Example:
```
agent_profile:
  role: backend specialist
  skills: [api, sql, testing]
  tools: [git, rg]
  constraints: ["no migrations"]
```

## Delegation
If the agent returns this:
```
needs_help: true
delegations:
  - title: "Add unit tests"
    body: "Test routing logic"
    labels: ["tests"]
    suggested_agent: "codex"
```
The orchestrator will:
- Create child tasks
- Block the parent until children are done
- Re-run the parent via `poll` or `rejoin`

## Concurrency + Locking
- `poll` runs new tasks in parallel.
- File writes are protected by a global lock (`tasks.yml.lock`).
- Each task also has a per-task lock to prevent double-run.

## GitHub Sync (Optional)
Sync tasks to GitHub Issues using `gh`.

### Pull issues into tasks.yml
```
just gh-pull
```

### Push tasks to GitHub issues
```
just gh-push
```

### Sync both directions
```
just gh-sync
```

### Notes
- The repo is resolved from `GITHUB_REPO` or `gh repo view`.
- Issues are created for tasks without `gh_issue_number`.
- If a task has label `no_gh` or `local-only`, it will not be synced.
- When a task is `done`, the issue is closed.
- On sync, task `summary` is posted as a comment (once per update).

## Notes
- `tasks.yml` is the system of record and can be synced to GitHub.
- Routing and profiles are LLM-generated; you can override them manually.
