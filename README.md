# Agent Orchestrator (bash, YAML + yq)

[![tests](https://github.com/gabrielkoerich/orchestrator/actions/workflows/tests.yml/badge.svg)](https://github.com/gabrielkoerich/orchestrator/actions/workflows/tests.yml)

A lightweight autonomous agent orchestrator that routes tasks, spawns specialized agent profiles, and supports delegation. Tasks live in `tasks.yml` (source of truth). Agents run via CLI tools (`codex`, `claude`, and `opencode`) in full agentic mode with tool access, and can delegate subtasks dynamically.

## Quick Setup
```bash
just install
```
Then run from any project directory:
```bash
cd /path/to/your/project
orchestrator status
```

## Requirements
- `yq` (mikefarah)
- `jq`
- `just`
- `python3`
- Agent CLIs in your PATH:
  - `codex`
  - `claude`
  - `opencode`
- Optional: `gh` for GitHub sync
- Optional: `bats` for tests

## Files
- `tasks.yml` — task database (YAML)
  - Not committed; generated from `tasks.example.yml`
- `jobs.yml` — scheduled job definitions (YAML)
  - Not committed; generated from `jobs.example.yml`
- `config.yml` — runtime configuration (YAML)
  - Not committed; generated from `config.example.yml`
- `skills.yml` — approved skill repositories and skill catalog
- `skills/` — cloned skill repositories (via `skills-sync`)
- `prompts/system.md` — system prompt (output format, constraints)
- `prompts/agent.md` — execution prompt (task details + enriched context)
- `prompts/route.md` — routing + profile generation prompt
- `prompts/review.md` — optional review agent prompt
- `scripts/*.sh` — orchestration commands
- `.orchestrator.example.yml` — template for per-project config override
- `scripts/cron_match.py` — lightweight cron expression matcher
- `tests/orchestrator.bats` — tests
- `contexts/` — persisted context files per task/profile
- `.orchestrator/` — runtime state (pid/log/locks/backoff/output files)

## Task Model
Each task includes:
- `id`, `title`, `body`, `labels`
- `status`: `new`, `routed`, `in_progress`, `done`, `blocked`, `needs_review`
- `agent`: executor (`codex`, `claude`, or `opencode`)
- `agent_model`: model chosen by the router
- `agent_profile`: dynamically generated role/skills/tools/constraints
- `selected_skills`: chosen skill ids from `skills.yml`
- `parent_id`, `children` for delegation
- `summary`, `reason` (why blocked/stuck)
- `accomplished`, `remaining`, `blockers`
- `files_changed`, `needs_help`
- `attempts`, `last_error`, `retry_at`
- `review_decision`, `review_notes`
- `history`: status changes with timestamps

GitHub metadata fields (optional):
- `gh_issue_number`, `gh_url`, `gh_state`, `gh_updated_at`, `gh_synced_at`

## How It Works
1. **Add a task** to `tasks.yml` (or via `just add`).
2. **Route the task** with an LLM that chooses executor + builds a specialized profile and selects skills.
3. **Run the task** with the chosen executor in agentic mode. The agent runs inside `$PROJECT_DIR` with full tool access (read files, edit code, run commands).
4. **Output**: the agent writes its results to `.orchestrator/output-{task_id}.json` (with stdout fallback for backward compatibility).
5. **Delegation**: if the agent returns `delegations`, child tasks are created and the parent is blocked until children finish.
6. **Rejoin**: parent resumes when children are done.
7. **Stuck detection**: if the agent returns `blocked` or `needs_review` with a `reason`, it's logged to history and posted as a GitHub comment tagging `@owner`.

## Routing: How the Orchestrator Picks an Agent

The orchestrator uses an LLM-as-classifier to route each task to the best agent. This is a non-agentic call (`--print`) — fast and cheap, no tool access needed.

### How It Works
1. `route_task.sh` sends the task title, body, labels, and the skills catalog to a lightweight LLM (default: `claude --model haiku --print`).
2. The router LLM returns JSON with:
   - **executor**: which agent to use (`codex`, `claude`, or `opencode`)
   - **model**: optional model suggestion (e.g. `sonnet`, `opus`, `gpt-4.1`)
   - **reason**: short explanation of the routing decision
   - **profile**: a specialized agent profile (role, skills, tools, constraints)
   - **selected_skills**: skill ids from the catalog
3. Sanity checks run — e.g. warns if a backend task gets routed to claude, or a docs task to codex.
4. If the router fails, it falls back to `config.yml`'s `router.fallback_executor` (default: `codex`).

### Router Config
```yaml
router:
  agent: "claude"       # which LLM does the routing
  model: "haiku"        # fast/cheap model for classification
  timeout_seconds: 120
  fallback_executor: "codex"  # safety net if routing fails
```

### Available Executors
| Executor | Best for |
|---|---|
| `codex` | Coding, repo changes, automation, tooling |
| `claude` | Analysis, synthesis, planning, writing |
| `opencode` | Lightweight coding and quick iterations |

The routing prompt is in `prompts/route.md`. The router only classifies — it never touches code or files.

## Agentic Mode

Once routed, agents run in full agentic mode with tool access:
- **Claude**: `-p` flag (non-interactive agentic mode), system prompt via `--append-system-prompt`
- **Codex**: `-q` flag (quiet non-interactive mode), system+agent prompt combined
- **OpenCode**: `opencode run` with combined prompt

Agents execute inside `$PROJECT_DIR` (the directory you ran `orchestrator` from), so they can read project files, edit code, and run commands. The context below is injected into the prompt as starting knowledge so agents don't waste time exploring — but since they have full tool access, they can also read any file themselves.

### Context Enrichment

Every agent receives a rich context built from multiple sources:

| Context | Source | When | Description |
|---|---|---|---|
| **System prompt** | `prompts/system.md` | Always | Output format, JSON schema, `reason` requirement, constraints |
| **Task details** | `tasks.yml` | Always | Title, body, labels, agent profile (role/skills/tools/constraints) |
| **Repo tree** | `find` in `$PROJECT_DIR` | Always | Truncated file listing (up to 200 files, excludes `.git`, `node_modules`, `vendor`, `.orchestrator`, `target`, `__pycache__`, `.venv`) |
| **Project instructions** | `$PROJECT_DIR/CLAUDE.md` + `README.md` | If files exist | Project-specific instructions and documentation |
| **Skills docs** | `skills/{id}/SKILL.md` | If skills selected by router | Full skill documentation for each selected skill |
| **Prior run context** | `contexts/task-{id}.md` | On retries | Logs from previous attempts (status, summary, reason, files changed) |
| **Parent context** | `tasks.yml` | For child tasks | Parent task summary + sibling task statuses |
| **Git diff** | `git diff --stat HEAD` in `$PROJECT_DIR` | On retries (attempts > 0) | Current uncommitted changes so the agent sees what was already modified |
| **Output file path** | `.orchestrator/output-{id}.json` | Always | Where the agent writes its JSON results |

### How Context Flows

```
run_task.sh
├── load_task()                    → TASK_TITLE, TASK_BODY, TASK_LABELS, AGENT_PROFILE_JSON, ...
├── load_task_context()            → TASK_CONTEXT     (prior run logs from contexts/task-{id}.md)
├── build_parent_context()         → PARENT_CONTEXT   (parent summary + sibling statuses)
├── build_project_instructions()   → PROJECT_INSTRUCTIONS  (CLAUDE.md + README.md content)
├── build_skills_docs()            → SKILLS_DOCS      (SKILL.md for each selected skill)
├── build_repo_tree()              → REPO_TREE        (truncated file listing)
├── build_git_diff()               → GIT_DIFF         (on retries only)
│
├── render_template("prompts/system.md")  → SYSTEM_PROMPT  (output format + constraints)
├── render_template("prompts/agent.md")   → AGENT_MESSAGE  (all context above)
│
└── agent invocation (cd $PROJECT_DIR)
    ├── claude -p --append-system-prompt "$SYSTEM_PROMPT" "$AGENT_MESSAGE"
    ├── codex -q "$SYSTEM_PROMPT\n\n$AGENT_MESSAGE"
    └── opencode run "$SYSTEM_PROMPT\n\n$AGENT_MESSAGE"
```

### Output
The agent writes results to `.orchestrator/output-{task_id}.json`. If the file isn't found (e.g. older agents or non-agentic fallback), the orchestrator falls back to parsing JSON from stdout via `normalize_json.py`, which handles Claude's result envelope, markdown fences, and mixed text.

## Usage

| Command | Description |
| --- | --- |
| `just add "Build router" "Add LLM router" "orchestration"` | Add a task (title required, body/labels optional). |
| `just list` | List tasks (id, status, agent, parent, title). |
| `just status` | Show status counts and recent tasks. |
| `just tree` | Show parent/child task tree. |
| `just dashboard` | Grouped dashboard view by status. |
| `just route 1` | Route task `1`. If no ID, route next `new` task. |
| `just run 1` | Run task `1`. If no ID, run next runnable. |
| `just next` | Route + run the next task in one step. |
| `just poll` | Run all runnable tasks in parallel (default 4 workers). |
| `just poll 8` | Run all runnable tasks with 8 workers. |
| `just rejoin` | Re-run blocked parents whose children are done. |
| `just watch` | Poll loop every 10s. |
| `just watch 5` | Poll loop every 5s. |
| `just serve` | Start server (poll + jobs + GitHub sync + auto-restart). |
| `just stop` | Stop server. |
| `just restart` | Restart server. |
| `just service-install` | Install macOS background service (launchd, auto-restart). |
| `just service-uninstall` | Remove macOS background service. |
| `just log` | Tail orchestrator log. |
| `just log 200` | Tail last 200 lines of log. |
| `just set-agent 1 claude` | Force a task to use a specific agent. |
| `just skills-sync` | Sync skills from registry to `skills/`. |
| `just test` | Run tests. |

### Scheduled Jobs

| Command | Description |
| --- | --- |
| `just jobs-add "0 9 * * *" "Daily Sync" "Pull and check" "sync"` | Add a scheduled job. |
| `just jobs-list` | List all jobs with status and next run. |
| `just jobs-remove daily-sync` | Remove a job. |
| `just jobs-enable daily-sync` | Enable a job. |
| `just jobs-disable daily-sync` | Disable a job. |
| `just jobs-tick` | Check and run due jobs (called automatically). |
| `just jobs-install` | Install crontab entry (ticks every minute). |
| `just jobs-uninstall` | Remove crontab entry. |

## Install As Global Tool
```bash
just install
```

This installs to `~/.orchestrator` and creates a wrapper at `~/.bin/orchestrator`.
The wrapper captures `PROJECT_DIR` from your current directory before switching to the orchestrator.

Make sure `~/.bin` is on your `PATH`:
```bash
export PATH="$HOME/.bin:$PATH"
```

Then run from any project:
```bash
cd ~/projects/my-app
orchestrator serve
```

## Background Service (macOS)

On macOS, the orchestrator can run as a launchd service that starts automatically on login and restarts on crashes.

```bash
just service-install    # install and start
just service-uninstall  # stop and remove
```

Or during initial setup:
```bash
just install  # prompts to install the service at the end
```

The service runs `orchestrator serve` in the background. Logs go to:
- `.orchestrator/launchd.out.log` — stdout
- `.orchestrator/launchd.err.log` — stderr

Check service status:
```bash
launchctl list | grep orchestrator
```

The plist is installed at `~/Library/LaunchAgents/com.orchestrator.serve.plist` with `KeepAlive` enabled and a 10-second throttle interval.

## Scheduled Jobs (Cron)

Jobs are defined in `jobs.yml` and create regular tasks on a schedule. They flow through the full pipeline (route, run, review, delegate, GitHub sync).

### How It Works
1. Define a job with a cron expression and a task template.
2. On each tick, the scheduler checks which jobs are due.
3. Each job tracks its `active_task_id`. If that task is still in-flight (any status except `done`), the job waits — no duplicates.
4. When the previous task completes, the job is free to create a new one on the next matching schedule.

### Running the Scheduler
**Option A: Crontab** (standalone, works without the server):
```bash
just jobs-install
```
This adds `* * * * * orchestrator jobs-tick` to your crontab.

**Option B: Server** (integrated, no crontab needed):
```bash
just serve
```
The server runs `jobs-tick` on every poll cycle automatically.

### Job Definition
```yaml
# jobs.yml
jobs:
  - id: daily-sync
    schedule: "0 9 * * *"
    task:
      title: "Daily code sync"
      body: "Pull latest changes, run linting, check for issues"
      labels: [sync]
      agent: ""          # empty = let router decide
    enabled: true
    last_run: null
    last_task_status: null
    active_task_id: null
```

### Schedule Expressions
Standard 5-field cron: `minute hour day_of_month month day_of_week`

Aliases: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`

Supports: wildcards (`*`), ranges (`1-5`), steps (`*/15`, `1-5/2`), lists (`1,3,5`).

### Dedup & Safety
- Each job has `active_task_id` tracking its current in-flight task.
- If the task is `new`, `routed`, `in_progress`, `blocked`, or `needs_review` — the job waits.
- Tasks can delegate children, get reviewed, retry — the job won't interfere.
- Only when the task reaches `done` does the job create a new one.
- Tasks from jobs get `scheduled` and `job:{id}` labels for easy filtering.
- All job-created tasks sync to GitHub issues like any other task.

## Dynamic Agent Profiles
The router generates a profile for each task, persisted in `tasks.yml`. You can edit it manually if the agent needs refinement.

Example:
```yaml
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

## Stuck Agent Detection & Owner Notification

When an agent can't complete a task, it reports why:
- `status: blocked` — waiting for a dependency or missing information
- `status: needs_review` — encountered an error or can't proceed

The agent must provide a `reason` field explaining what happened, what it tried, and what it needs. This reason is:
1. **Persisted** in `tasks.yml` (the `reason` field)
2. **Logged** in task history with timestamps
3. **Appended** to the task context file (`contexts/task-{id}.md`)
4. **Posted** as a GitHub issue comment (if GitHub sync is enabled) tagging `@owner` (extracted from `gh.repo`, e.g. `gabrielkoerich/app` → `@gabrielkoerich`)

The GitHub comment includes: status, summary, reason, error, blockers, accomplished items, remaining items, files changed, and attempt count.

## Logging & Observability

All state lives under `~/.orchestrator` (the install dir). Logs and runtime files are in the `.orchestrator/` subdirectory within it.

### Log Files

| File | Path | Description |
|---|---|---|
| **Server log** | `.orchestrator/orchestrator.log` | Main loop output: ticks, poll, jobs, gh sync, restarts |
| **Archive log** | `.orchestrator/orchestrator.archive.log` | Previous server sessions (rotated on each `just serve` start) |
| **Jobs log** | `.orchestrator/jobs.log` | Crontab tick output (when using `just jobs-install`) |

View the server log:
```bash
just log          # tail last 50 lines
just log 200      # tail last 200 lines
```

Or tail it live while the server runs:
```bash
TAIL_LOG=1 just serve
```

### Per-Task Logs

| File | Path | Description |
|---|---|---|
| **Task context** | `contexts/task-{id}.md` | Appended after each run: timestamp, status, summary, reason, files changed |
| **Task history** | `tasks.yml` `.history[]` | Status transitions with timestamps and notes |
| **Agent output** | `.orchestrator/output-{id}.json` | Structured JSON from the last agent run |
| **Route prompt** | `.orchestrator/route-prompt-{id}.txt` | The prompt sent to the router (for debugging routing decisions) |
| **Failed response** | `contexts/response-{id}.md` | Raw agent output when JSON parsing fails |

### GitHub (if synced)

When GitHub sync is enabled, status updates are also posted as issue comments — including summary, reason, blockers, files changed, and attempt count. Blocked/needs_review tasks tag `@owner` for attention.

### What Gets Logged Where

| Event | Server log | Task context | Task history | GitHub |
|---|---|---|---|---|
| Tick/poll cycle | x | | | |
| Task started | x | | x | |
| Agent completed | x | x | x | x |
| Agent blocked/stuck | x | x | x | x (tags owner) |
| Invalid response | x | x (raw saved) | x | |
| Review result | x | | x | x |
| Delegation | x | | x | x |
| Job triggered | x | | | |
| Config/code restart | x | | | |

## Per-Project Config

Place a `.orchestrator.yml` in your project root to override the global config for that project. Only include the keys you want to override — everything else falls through to `~/.orchestrator/config.yml`.

```yaml
# myproject/.orchestrator.yml
gh:
  repo: "myorg/myproject"
  project_id: "PVT_..."
  sync_label: ""
workflow:
  auto_close: false
  review_owner: "@myhandle"
router:
  model: "sonnet"
```

This lets you:
- Use a different GitHub repo/project per project
- Customize workflow settings (review, auto-close) per project
- Override the router model or fallback agent
- Keep project-specific config in version control

The server restarts automatically when `.orchestrator.yml` changes.

## Config Reference
All runtime configuration lives in `config.yml`.

| Section | Key | Description | Default |
| --- | --- | --- | --- |
| top-level | `project_dir` | Override project directory (auto-detected from CWD). | `""` |
| `workflow` | `auto_close` | Auto-close GitHub issues when tasks are `done`. | `true` |
| `workflow` | `review_owner` | GitHub handle to tag when review is needed. | `@owner` |
| `workflow` | `enable_review_agent` | Run a review agent after completion. | `false` |
| `workflow` | `review_agent` | Executor for the review agent. | `claude` |
| `router` | `agent` | Default router executor. | `claude` |
| `router` | `model` | Router model name. | `haiku` |
| `router` | `timeout_seconds` | Router timeout (0 disables timeout). | `120` |
| `router` | `fallback_executor` | Fallback executor when router fails. | `codex` |
| `router` | `allowed_tools` | Default tool allowlist used in routing prompts. | `[yq, jq, bash, ...]` |
| `router` | `default_skills` | Skills always included in routing. | `[gh, git-worktree]` |
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

## Context Persistence
Task and profile contexts are persisted under `contexts/`:
- `contexts/task-<id>.md` — logs from each run (status, summary, reason, files)
- `contexts/profile-<role>.md` — role-specific context

The orchestrator loads both into the prompt and appends a log entry after each run.

## Delegation
If the agent returns this:
```json
{
  "needs_help": true,
  "delegations": [
    {
      "title": "Add unit tests",
      "body": "Test routing logic",
      "labels": ["tests"],
      "suggested_agent": "codex"
    }
  ]
}
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
```yaml
workflow:
  enable_review_agent: true
  review_agent: "claude"
```
The review agent sees the task summary, files changed, and git diff.

## GitHub Sync (Optional)
Sync tasks to GitHub Issues using `gh`.

<details>
<summary>GitHub Integration: Token Type and Permissions</summary>

**Recommended:** Fine-grained PAT scoped to the target repo(s).

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
```yaml
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

### Owner Tagging
When a task is `blocked` or `needs_review`, the GitHub comment automatically tags `@owner` (extracted from `gh.repo`). For example, if `gh.repo` is `gabrielkoerich/bean`, the comment tags `@gabrielkoerich`.

The comment includes the full context: what the agent tried, why it's stuck, what it accomplished so far, and what remains.

### Notes
- The repo is resolved from `config.yml` or `gh repo view`.
- Issues are created for tasks without `gh_issue_number`.
- If a task has label `no_gh` or `local-only`, it will not be synced.
- If `config.yml` `gh.sync_label` is set, only tasks/issues with that label are synced.
- If `config.yml` `gh.enabled` is `false`, GitHub sync is disabled.
- Task status is synced to issue labels using `status:<status>`.
- When a task is `done`, `auto_close` controls whether to close the issue or tag the owner for review.
- Scheduled job tasks get `scheduled` and `job:{id}` labels and sync to GitHub like any other task.
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

## Notes
- `tasks.yml` is the system of record and can be synced to GitHub.
- Routing and profiles are LLM-generated; you can override them manually.
- Agents run in agentic mode inside `$PROJECT_DIR` with full tool access.
- The router stays non-agentic (`--print`) — it's a classification task.

---

## Changelog

### Unreleased

#### Agentic Mode
- Agents now run in full agentic mode with tool access instead of single-turn `--print`/`exec --json`.
- Claude uses `-p` (non-interactive agentic), Codex uses `-q` (quiet non-interactive), OpenCode uses `opencode run`.
- Agents execute inside `$PROJECT_DIR` and can read files, edit code, and run commands.
- Output is written to `.orchestrator/output-{task_id}.json` (stdout parsing kept as fallback).

#### Context Enrichment
- Agents receive repo file tree, project instructions (CLAUDE.md/README.md), skill docs, parent/sibling context, and git diff.
- Split prompt into system prompt (`prompts/system.md`) + agent message (`prompts/agent.md`).
- `render_template` rewritten to use env-var-based regex substitution (replaces 9 positional params).

#### PROJECT_DIR
- The installed binary (`~/.bin/orchestrator`) now captures `PROJECT_DIR` from CWD before switching to `~/.orchestrator`.
- Agents run inside the project directory, not the orchestrator directory.
- `project_dir` config option added for manual override.

#### Scheduled Jobs (Cron)
- New `jobs.yml` for defining scheduled tasks with cron expressions.
- `jobs_tick.sh` evaluates due jobs and creates tasks, with per-job dedup via `active_task_id`.
- `jobs_add.sh`, `jobs_list.sh`, `jobs_remove.sh` for job management.
- `jobs_install.sh` / `jobs_uninstall.sh` for crontab integration.
- Supports standard cron expressions and aliases (`@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`).
- `cron_match.py` — lightweight cron expression matcher (no external dependencies).
- Jobs integrated into `serve.sh` loop (ticks every poll cycle).
- Job-created tasks get `scheduled` and `job:{id}` labels.

#### Stuck Agent Detection & Owner Notification
- New `reason` field in task schema — agents explain why when returning `blocked` or `needs_review`.
- System prompt instructs agents to be specific about what went wrong and what they need.
- Reason persisted in tasks.yml, task history, and context files.
- GitHub push posts detailed comments on blocked/needs_review tasks tagging `@owner` (extracted from `gh.repo` slug).
- Comments include: status, summary, reason, error, blockers, accomplished, remaining, files, attempt count.

#### Background Service (macOS)
- `just service-install` / `just service-uninstall` for launchd integration.
- Auto-starts on login, auto-restarts on crash (KeepAlive + 10s throttle).
- Offered during `just install` on macOS.
- Logs to `.orchestrator/launchd.{out,err}.log`.

#### Per-Project Config
- `.orchestrator.yml` in project root overrides global `config.yml` (deep merge, project wins).
- Supports per-project GitHub repo, project, workflow, and router settings.
- Server restarts automatically when `.orchestrator.yml` changes.
- `gh_project_apply.sh` writes to global config, not the merged overlay.

#### Logging & Observability
- Documented all log locations: server log, archive, jobs log, task context files, task history, agent output, route prompts.
- Added "Logging & Observability" section to README with event-to-log mapping table.

#### Code Cleanup
- `load_task()` replaces triple yq fallback with single JSON load + jq extraction.
- `repo_owner()` helper extracts username from `gh.repo` config.
- `init_jobs_file()` helper for jobs.yml initialization.
- `jobs.yml` preserved across `just install` (rsync exclude).

#### Tests
- 24 tests (up from 13), covering: output file reading, stdout fallback, cron matching, job creation, dedup, disable, removal, project config overlay.
