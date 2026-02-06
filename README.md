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
  - Not committed; generated from `tasks.example.yml`
- `prompts/route.md` — routing + profile generation prompt
- `prompts/agent.md` — execution prompt (includes profile + context)
- `prompts/review.md` — optional review agent prompt
- `scripts/*.sh` — orchestration commands
- `tests/orchestrator.bats` — tests
- `contexts/` — persisted context files per task/profile

## Task Model
Each task includes:
- `id`, `title`, `body`, `labels`
- `status`: `new`, `routed`, `in_progress`, `done`, `blocked`, `needs_review`
- `agent`: executor (`codex` or `claude`)
- `agent_profile`: dynamically generated role/skills/tools/constraints
- `parent_id`, `children` for delegation
- `summary`, `files_changed`, `needs_help`
- `attempts`, `last_error`, `retry_at`
- `review_decision`, `review_notes`
- `history`: status changes with timestamps

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
```bash
just add "Build router" "Add LLM router and task runner" "orchestration,router"
```bash
Body and labels are optional:
```bash
just add "Build router"
```bash

### List tasks
```bash
just list
```bash

### Status dashboard
```bash
just status
```bash

### Task tree
```bash
just tree
```bash

### Dashboard view
```bash
just dashboard
```bash

### Route a task
```bash
just route 1
```bash
If no ID is provided, the next `new` task is routed.

### Run a task
```bash
just run 1
```bash
If no ID is provided, the next `new` task is run (or `routed` if no `new`).

### Run the next task
```bash
just next
```bash

### Poll all tasks (parallel)
```bash
just poll
just poll 8
```bash

### Rejoin blocked parents (parallel)
```bash
just rejoin
```bash

### Watch loop
```bash
just watch
just watch 5
```bash

### Tests
```bash
just test
```bash

## Install As Global Tool
```bash
just setup
```bash

This installs to `~/.orchestrator` and creates a wrapper at `~/.bin/orchestrator`.
Make sure `~/.bin` is on your `PATH`:
```bash
export PATH="$HOME/.bin:$PATH"
```bash

## Dynamic Agent Profiles
The router generates a profile for each task, persisted in `tasks.yml`. You can edit it manually if the agent needs refinement.

Example:
```bash
agent_profile:
  role: backend specialist
  skills: [api, sql, testing]
  tools: [git, rg]
  constraints: ["no migrations"]
```bash

## Context Persistence
Task and profile contexts are persisted under `contexts/`:
- `contexts/task-<id>.md`
- `contexts/profile-<role>.md`

The orchestrator loads both into the prompt and appends a short log entry after each run.

## Delegation
If the agent returns this:
```bash
needs_help: true
delegations:
  - title: "Add unit tests"
    body: "Test routing logic"
    labels: ["tests"]
    suggested_agent: "codex"
```bash
The orchestrator will:
- Create child tasks
- Block the parent until children are done
- Re-run the parent via `poll` or `rejoin`

## Concurrency + Locking
- `poll` runs new tasks in parallel.
- File writes are protected by a global lock (`tasks.yml.lock`).
- Each task also has a per-task lock to prevent double-run.
- Stale locks are auto-cleared after `LOCK_STALE_SECONDS` (default 600).

## Review Agent (Optional)
Enable a post-run review:
```bash
ENABLE_REVIEW_AGENT=1 REVIEW_AGENT=claude just run 1
```bash

## GitHub Sync (Optional)
Sync tasks to GitHub Issues using `gh`.

<details>
<summary>GitHub Integration: Token Type and Permissions</summary>

**Recommended:** Fine‑grained PAT scoped to the target repo(s).

Repository permissions:
- Issues: Read + Write
- Metadata: Read
- Contents: Read (optional)

Organization permissions (for Projects v2):
- Projects: Read + Write

Classic PATs will also work but are broader in scope.
</details>

### GitHub Setup
1. Install and authenticate:
```bash
gh auth login
```bash
2. Verify access:
```bash
gh repo view
```bash
3. (Optional) Set repo explicitly:
```bash
export GITHUB_REPO=owner/repo
```bash
4. (Optional) Sync only labeled issues:
```bash
export GH_SYNC_LABEL=sync
```bash
5. (Recommended) Put token in `.env`:
```bash
export GH_TOKEN=YOUR_TOKEN
```bash

### Pull issues into tasks.yml
```bash
just gh-pull
```bash

### Push tasks to GitHub issues
```bash
just gh-push
```bash

### Sync both directions
```bash
just gh-sync
```bash

### Notes
- The repo is resolved from `GITHUB_REPO` or `gh repo view`.
- Issues are created for tasks without `gh_issue_number`.
- If a task has label `no_gh` or `local-only`, it will not be synced.
- If `GH_SYNC_LABEL` (or `gh.sync_label`) is set, only tasks/issues with that label are synced.
- Task status is synced to issue labels using `status:<status>`.
- When a task is `done`, the issue is closed.
- On sync, task `summary` is posted as a comment (once per update).

### Projects (Optional)
Provide:
- `GH_PROJECT_ID`
- `GH_PROJECT_STATUS_FIELD_ID`
- `GH_PROJECT_STATUS_MAP_JSON` (e.g. `{"new":"<optionId>","in_progress":"<optionId>","done":"<optionId>"}`)

#### Finding IDs
1. Project ID (GraphQL):
```bash
gh api graphql -f query='query($org:String!, $num:Int!){ organization(login:$org){ projectV2(number:$num){ id } } }' -f org=YOUR_ORG -f num=PROJECT_NUMBER
```bash
2. Status field ID + option IDs:
```bash
gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:50){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name } } } } } } }' -f project=YOUR_PROJECT_ID
```bash
3. Example mapping:
```bash
export GH_PROJECT_STATUS_MAP_JSON='{"new":"<optionId>","in_progress":"<optionId>","done":"<optionId>"}'
```bash

## Notes
- `tasks.yml` is the system of record and can be synced to GitHub.
- Routing and profiles are LLM-generated; you can override them manually.
