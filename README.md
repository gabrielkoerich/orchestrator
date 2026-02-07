# Agent Orchestrator (bash, YAML + yq)

A lightweight autonomous agent orchestrator that routes tasks, spawns specialized agent profiles, and supports delegation. Tasks live in `tasks.yml` (source of truth). Agents run via CLI tools (`codex`, `claude`, and `opencode`) and can delegate subtasks dynamically.

## Quick Setup
```bash
just install
```
Then run:
```bash
orchestrator status
```

## Requirements
- `yq` (mikefarah)
- `just`
- Agent CLIs in your PATH:
  - `codex`
  - `claude`
  - `opencode`
- Optional: `gh` for GitHub sync

## Files
- `tasks.yml` — task database (YAML)
  - Not committed; generated from `tasks.example.yml`
- `config.yml` — runtime configuration (YAML)
  - Not committed; generated from `config.example.yml`
- `skills.yml` — approved skill repositories and skill catalog
- `skills/` — cloned skill repositories (via `skills-sync`)
- `prompts/route.md` — routing + profile generation prompt
- `prompts/agent.md` — execution prompt (includes profile + context)
- `prompts/review.md` — optional review agent prompt
- `scripts/*.sh` — orchestration commands
- `tests/orchestrator.bats` — tests
- `contexts/` — persisted context files per task/profile
- `.orchestrator/` — runtime state (pid/log/locks/backoff)

## Task Model
Each task includes:
- `id`, `title`, `body`, `labels`
- `status`: `new`, `routed`, `in_progress`, `done`, `blocked`, `needs_review`
- `agent`: executor (`codex`, `claude`, or `opencode`)
- `agent_model`: model chosen by the router
- `agent_profile`: dynamically generated role/skills/tools/constraints
- `selected_skills`: chosen skill ids from `skills.yml`
- `parent_id`, `children` for delegation
- `summary`, `accomplished`, `remaining`, `blockers`
- `files_changed`, `needs_help`
- `attempts`, `last_error`, `retry_at`
- `review_decision`, `review_notes`
- `history`: status changes with timestamps

GitHub metadata fields (optional):
- `gh_issue_number`, `gh_url`, `gh_state`, `gh_updated_at`, `gh_synced_at`

## How It Works
1. **Add a task** to `tasks.yml` (or via `just add`).
2. **Route the task** with an LLM that chooses executor + builds a specialized profile and selects skills.
3. **Run the task** with the chosen executor, profile, and skills.
4. **Delegation**: if the agent returns `delegations`, child tasks are created and the parent is blocked until children finish.
5. **Rejoin**: parent resumes when children are done.

## Usage

| Command | Description |
| --- | --- |
| `just add "Build router" "Add LLM router and task runner" "orchestration,router"` | Add a task (title required, body/labels optional). |
| `just add "Build router"` | Add a minimal task with only a title. |
| `just list` | List tasks (id, status, agent, parent, title). |
| `just status` | Show status counts and recent tasks. |
| `just tree` | Show parent/child task tree. |
| `just dashboard` | Grouped dashboard view by status. |
| `just route 1` | Route task `1`. If no ID, route next `new` task. |
| `just run 1` | Run task `1`. If no ID, run next `new` (or `routed` if none). |
| `just next` | Route + run the next task in one step. |
| `just poll` | Run all runnable tasks in parallel (default 4 workers). |
| `just poll 8` | Run all runnable tasks with 8 workers. |
| `just rejoin` | Re-run blocked parents whose children are done. |
| `just watch` | Poll loop every 10s. |
| `just watch 5` | Poll loop every 5s. |
| `just serve` | Start server (poll + GitHub sync + auto-restart). |
| `just stop` | Stop server. |
| `just restart` | Restart server. |
| `just log` | Tail orchestrator log. |
| `just log 200` | Tail last 200 lines of log. |
| `just skills-sync` | Sync skills from registry to `skills/`. |
| `just test` | Run tests. |

## Install As Global Tool
```bash
just install
```

This installs to `~/.orchestrator` and creates a wrapper at `~/.bin/orchestrator`.
Make sure `~/.bin` is on your `PATH`:
```bash
export PATH="$HOME/.bin:$PATH"
```

## Dynamic Agent Profiles
The router generates a profile for each task, persisted in `tasks.yml`. You can edit it manually if the agent needs refinement.

Example:
```bash
agent_profile:
  role: backend specialist
  skills: [api, sql, testing]
  tools: [git, rg]
  constraints: ["no migrations"]
```

## Skills Catalog
`skills.yml` defines approved skill repositories and a catalog of skills. The router selects skill ids and stores them in `selected_skills`.
Clone or update skills with:
```bash
just skills-sync
```

## Config Reference
All runtime configuration lives in `config.yml`.

| Section | Key | Description | Default |
| --- | --- | --- | --- |
| `workflow` | `auto_close` | Auto-close GitHub issues when tasks are `done`. If false, move to Review and tag `review_owner`. | `true` |
| `workflow` | `review_owner` | GitHub handle to tag when review is needed. | `@owner` |
| `workflow` | `enable_review_agent` | Run a review agent after completion. | `false` |
| `workflow` | `review_agent` | Executor for the review agent. | `claude` |
| `router` | `agent` | Default router executor. | `claude` |
| `router` | `model` | Router model name. | `haiku` |
| `router` | `timeout_seconds` | Router timeout (0 disables timeout). | `120` |
| `router` | `fallback_executor` | Fallback executor when router fails. | `codex` |
| `router` | `allowed_tools` | Default tool allowlist used in routing prompts. | `["yq","jq","bash","just","git","rg","sed","awk","python3","node","npm","bun"]` |
| `router` | `default_skills` | Skills always included in routing. | `["gh","git-worktree"]` |
| `llm` | `input_format` | CLI input format override. | `""` |
| `llm` | `output_format` | CLI output format override. | `"json"` |
| `gh` | `enabled` | Enable GitHub sync. | `true` |
| `gh` | `repo` | Default repo (`owner/repo`). | `"owner/repo"` |
| `gh` | `sync_label` | Only sync tasks/issues with this label (empty = all). | `"sync"` |
| `gh` | `project_id` | GitHub Project v2 ID. | `""` |
| `gh` | `project_status_field_id` | Status field ID in Project v2. | `""` |
| `gh` | `project_status_map` | Mapping for `backlog/in_progress/review/done` option IDs. | `{}` |
| `gh.backoff` | `mode` | Rate-limit behavior: `wait` or `skip`. | `"wait"` |
| `gh.backoff` | `base_seconds` | Initial backoff duration in seconds. | `30` |
| `gh.backoff` | `max_seconds` | Max backoff duration in seconds. | `900` |

The router still builds dynamic profiles, but these defaults apply to every task.

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
```
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
Enable a post-run review in config:
```bash
workflow:
  enable_review_agent: true
  review_agent: "claude"
```

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
```
2. Verify access:
```bash
gh repo view
```
Project fields belong in `config.yml`:
```bash
gh:
  project_id: ""
  project_status_field_id: ""
  project_status_map:
    backlog: ""
    in_progress: ""
    review: ""
    done: ""
```
To discover Project field and option IDs:
```bash
just gh-project-info
```
To auto-fill the Status field/options into config:
```bash
just gh-project-info-fix
```

### Pull issues into tasks.yml
```bash
just gh-pull
```

### Push tasks to GitHub issues
```bash
just gh-push
```

### Sync both directions
```bash
just gh-sync
```

### Notes
- The repo is resolved from `config.yml` or `gh repo view`.
- Issues are created for tasks without `gh_issue_number`.
- If a task has label `no_gh` or `local-only`, it will not be synced.
- If `config.yml` `gh.sync_label` is set, only tasks/issues with that label are synced.
- If `config.yml` `gh.enabled` is `false`, GitHub sync is disabled.
- Task status is synced to issue labels using `status:<status>`.
- When a task is `done`, `auto_close` controls whether to close the issue or move it to Review and tag the owner.
- On sync, task updates are posted as comments with accomplished/remaining/blockers.
- If status is `blocked`, the comment tags the review owner and label `status:blocked` is applied.
- Agents never call GitHub directly; the orchestrator posts comments and status updates so it can back off safely when rate-limited.

### GitHub Backoff
When GitHub rate limits or abuse detection triggers, the orchestrator sleeps and retries instead of hammering the API.

Config keys:
- `gh.backoff.mode` — `wait` (default) or `skip`
- `gh.backoff.base_seconds` — initial backoff duration
- `gh.backoff.max_seconds` — maximum backoff duration

The backoff is shared across pull/push/comment/project updates, so a single rate limit event pauses all GitHub writes.

### Projects (Optional)
Provide in `config.yml`:
- `gh.project_id`
- `gh.project_status_field_id`
- `gh.project_status_map` (Backlog/In Progress/Review/Done option IDs)

#### Finding IDs
1. Project ID (GraphQL):
```bash
gh api graphql -f query='query($org:String!, $num:Int!){ organization(login:$org){ projectV2(number:$num){ id } } }' -f org=YOUR_ORG -f num=PROJECT_NUMBER
```
2. Status field ID + option IDs (or use `just gh-project-info`):
```bash
gh api graphql -f query='query($project:ID!){ node(id:$project){ ... on ProjectV2 { fields(first:50){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name } } } } } } }' -f project=YOUR_PROJECT_ID
```
3. Example mapping:
```bash
export GITHUB_PROJECT_STATUS_MAP_JSON='{"backlog":"<optionId>","in_progress":"<optionId>","review":"<optionId>","done":"<optionId>"}'
```

## Notes
- `tasks.yml` is the system of record and can be synced to GitHub.
- Routing and profiles are LLM-generated; you can override them manually.
