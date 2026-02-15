# Agent Orchestrator (bash, YAML + yq)

[![CI](https://github.com/gabrielkoerich/orchestrator/actions/workflows/release.yml/badge.svg)](https://github.com/gabrielkoerich/orchestrator/actions/workflows/release.yml)

A lightweight autonomous agent orchestrator that routes tasks, spawns specialized agent profiles, and supports delegation. Tasks live in `tasks.yml` (source of truth). Agents run via CLI tools (`codex`, `claude`, and `opencode`) in full agentic mode with tool access, and can delegate subtasks dynamically.

## Install

### Homebrew (recommended)
```bash
brew tap gabrielkoerich/orchestrator
brew install orchestrator
```

All dependencies (`yq`, `jq`, `just`, `python3`) are installed automatically.

### From source
```bash
git clone https://github.com/gabrielkoerich/orchestrator.git
cd orchestrator
just install
```

Requires `yq`, `jq`, `just`, `python3` in your PATH.

### Agent CLIs

Install at least one:
```bash
brew install --cask claude-code   # Claude
brew install --cask codex         # Codex
brew install opencode             # OpenCode
```

Optional: `gh` for GitHub sync, `bats` for tests.

## Quick Start
```bash
cd ~/projects/my-app
orchestrator init          # configure project (optional GitHub setup)
orchestrator add "title"   # add a task
orchestrator next          # route + run next task
orchestrator serve         # start background server
```

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
- `prompts/plan.md` — planning/decomposition prompt (break task into subtasks)
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
- `status`: `new`, `routed`, `in_progress`, `done`, `blocked`
- `agent`: executor (`codex`, `claude`, or `opencode`)
- `agent_model`: model chosen by the router
- `agent_profile`: dynamically generated role/skills/tools/constraints
- `selected_skills`: chosen skill ids from `skills.yml`
- `parent_id`, `children` for delegation
- `summary`, `reason` (why blocked/stuck)
- `accomplished`, `remaining`, `blockers`
- `files_changed`, `needs_help`
- `attempts`, `last_error`
- `review_decision`, `review_notes`
- `history`: status changes with timestamps

GitHub metadata fields (optional):
- `gh_issue_number`, `gh_url`, `gh_state`, `gh_updated_at`, `gh_synced_at`

## How It Works
1. **Add a task** to `tasks.yml` (or via `orchestrator add`).
2. **Route the task** with an LLM that chooses executor + builds a specialized profile and selects skills.
3. **Run the task** with the chosen executor in agentic mode. The agent runs inside `$PROJECT_DIR` with full tool access (read files, edit code, run commands).
4. **Output**: the agent writes its results to `.orchestrator/output-{task_id}.json` (with stdout fallback for backward compatibility).
5. **Delegation**: if the agent returns `delegations`, child tasks are created and the parent is blocked until children finish.
6. **Rejoin**: parent resumes when children are done.
7. **Error handling**: if the agent fails or returns `blocked` with a `reason`, the task is blocked, the error is commented on the GitHub issue, and a `blocked` label is added.

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
- **Claude**: `-p` flag (non-interactive agentic mode), `--output-format json`, system prompt via `--append-system-prompt`
- **Codex**: `-q` flag (quiet non-interactive mode), `--json`, system+agent prompt combined
- **OpenCode**: `opencode run --format json` with combined prompt

Agents execute inside `$PROJECT_DIR` (the directory you ran `orchestrator` from), so they can read project files, edit code, and run commands. The context below is injected into the prompt as starting knowledge so agents don't waste time exploring — but since they have full tool access, they can also read any file themselves.

### Agent Safety Rules

Agents are constrained by rules in the system prompt:
- **No `rm`**: `--disallowedTools` blocks `rm` — agents must use `trash` (macOS) or `trash-put` (Linux)
- **No commits to main**: Agents must always work in feature branches
- **Required skills**: Skills listed in `workflow.required_skills` are marked `[REQUIRED]` in the agent prompt and must be followed exactly (e.g. `gh-issue-worktree` for branch/PR workflow)
- **GitHub issue linking**: If a task has a linked issue, the agent receives the issue reference for branch naming and PR linking
- **Cost-conscious sub-agents**: Agents are instructed to use cheap models for routine sub-agent work

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
    ├── claude -p --output-format json --append-system-prompt "$SYSTEM_PROMPT" "$AGENT_MESSAGE"
    ├── codex -q --json "$SYSTEM_PROMPT\n\n$AGENT_MESSAGE"
    └── opencode run --format json "$SYSTEM_PROMPT\n\n$AGENT_MESSAGE"
```

### Output
The agent writes results to `.orchestrator/output-{task_id}.json`. If the file isn't found (e.g. older agents or non-agentic fallback), the orchestrator falls back to parsing JSON from stdout via `normalize_json.py`, which handles Claude's result envelope, markdown fences, and mixed text.

## Usage

| Command | Description |
| --- | --- |
| `orchestrator add "Build router" "Add LLM router" "orchestration"` | Add a task (title required, body/labels optional). |
| `orchestrator plan "Implement auth" "Add login, signup, reset" "backend"` | Add a task that will be decomposed into subtasks first. |
| `orchestrator list` | List tasks (id, status, agent, parent, title). |
| `orchestrator status` | Show status counts and recent tasks. |
| `orchestrator tree` | Show parent/child task tree. |
| `orchestrator dashboard` | Grouped dashboard view by status. |
| `orchestrator route 1` | Route task `1`. If no ID, route next `new` task. |
| `orchestrator run 1` | Run task `1`. If no ID, run next runnable. |
| `orchestrator next` | Route + run the next task in one step. |
| `orchestrator poll` | Run all runnable tasks in parallel (default 4 workers). |
| `orchestrator poll 8` | Run all runnable tasks with 8 workers. |
| `orchestrator rejoin` | Re-run blocked parents whose children are done. |
| `orchestrator watch` | Poll loop every 10s. |
| `orchestrator watch 5` | Poll loop every 5s. |
| `orchestrator init` | Initialize orchestrator for current project. |
| `orchestrator init --repo "org/repo"` | Non-interactive init with GitHub repo. |
| `orchestrator projects` | List all projects with tasks. |
| `orchestrator agents` | List installed agent CLIs. |
| `orchestrator serve` | Start server (poll + jobs + GitHub sync + auto-restart). |
| `orchestrator stop` | Stop server. |
| `orchestrator restart` | Restart server. |
| `brew services start orchestrator` | macOS background service (Homebrew). |
| `orchestrator service-install` | macOS background service (from-source install). |
| `orchestrator service-uninstall` | Remove macOS background service. |
| `orchestrator log` | Tail orchestrator log. |
| `orchestrator log 200` | Tail last 200 lines of log. |
| `orchestrator set-agent 1 claude` | Force a task to use a specific agent. |
| `orchestrator skills-sync` | Sync skills from registry to `skills/`. |
| `orchestrator test` | Run tests. |
| `orchestrator --version` | Show version. |

### Scheduled Jobs

| Command | Description |
| --- | --- |
| `orchestrator jobs-add "0 9 * * *" "Daily Sync" "Pull and check" "sync"` | Add a scheduled job. |
| `orchestrator jobs-list` | List all jobs with status and next run. |
| `orchestrator jobs-remove daily-sync` | Remove a job. |
| `orchestrator jobs-enable daily-sync` | Enable a job. |
| `orchestrator jobs-disable daily-sync` | Disable a job. |
| `orchestrator jobs-tick` | Check and run due jobs (called automatically). |
| `orchestrator jobs-install` | Install crontab entry (ticks every minute). |
| `orchestrator jobs-uninstall` | Remove crontab entry. |

## Install As Global Tool

### Via Homebrew (recommended)
```bash
brew tap gabrielkoerich/orchestrator
brew install orchestrator
```

### From source
```bash
just install
```

This installs to `~/.orchestrator` and creates a wrapper at `~/.bin/orchestrator`.
Make sure `~/.bin` is on your `PATH`:
```bash
export PATH="$HOME/.bin:$PATH"
```

Then run from any project:
```bash
cd ~/projects/my-app
orchestrator init    # optional: configure GitHub integration
orchestrator serve
```

## Per-Project Isolation

Each task is tagged with its project directory. When you run commands from a project, you only see that project's tasks:

```bash
cd ~/projects/app-a && orchestrator add "Task A"
cd ~/projects/app-b && orchestrator add "Task B"

cd ~/projects/app-a && orchestrator list  # shows only Task A
cd ~/projects/app-b && orchestrator list  # shows only Task B
```

A single `orchestrator serve` handles all projects — it reads each task's `dir` field and runs agents in the correct directory.

List all projects with tasks:
```bash
orchestrator projects
```

## Background Service (macOS)

### Via Homebrew (recommended)
```bash
brew services start orchestrator    # start (auto-starts on login)
brew services stop orchestrator     # stop
brew services restart orchestrator  # restart
```

### Via launchd (from-source installs)
```bash
orchestrator service-install    # install and start
orchestrator service-uninstall  # stop and remove
```

The service runs `orchestrator serve` in the background. Check status:
```bash
brew services list | grep orchestrator   # Homebrew
launchctl list | grep orchestrator       # launchd
```

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
orchestrator jobs-install
```
This adds `* * * * * orchestrator jobs-tick` to your crontab.

**Option B: Server** (integrated, no crontab needed):
```bash
orchestrator serve
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
- If the task is `new`, `routed`, `in_progress`, or `blocked` — the job waits.
- Tasks can delegate children, get reviewed, or get blocked — the job won't interfere.
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

### Required Skills
Skills listed in `workflow.required_skills` are always injected into agent prompts, marked `[REQUIRED]`, and enforced regardless of what the router selects. Configure in `config.yml`:
```yaml
workflow:
  required_skills:
    - gh-issue-worktree   # branch/PR workflow
    - github              # GitHub CLI operations
    - gh-pr-polish        # PR titles and bodies
```

### Commit Pinning
Skill repositories are pinned to audited commit SHAs in `skills.yml` to prevent supply chain attacks:
```yaml
repositories:
  - name: gabrielkoerich
    url: https://github.com/gabrielkoerich/skills
    pin: 226f5f11346eddceebf017746aa5cd660ef3af20
```
When pinned, `skills-sync` checks out the exact commit instead of pulling latest.

### Syncing
Clone or update skills with:
```bash
orchestrator skills-sync
```

## Error Handling & GitHub Issue Feedback

When an agent fails, the orchestrator classifies the error and blocks the task:

### Error Classification
| Error Type | Detection | Action |
|---|---|---|
| **Auth/billing** | Pattern match on stderr/stdout (401, 403, expired key, quota, etc.) | Block + comment on issue |
| **Timeout** | Exit code 124 | Block + comment on issue |
| **Generic failure** | Any non-zero exit | Block + comment on issue |
| **Invalid response** | No JSON in output file or stdout | Block + comment on issue |

### What Happens on Failure
1. Task status set to `blocked` (no auto-retry)
2. Error details saved to `last_error` field in `tasks.yml`
3. Error logged to task history with timestamp
4. **GitHub issue comment** posted with error details, agent name, and attempt count
5. **`blocked` label** added to the GitHub issue

### Unblocking
Tasks stay blocked until you manually investigate and unblock them:
1. Check the error on the GitHub issue (or in `tasks.yml`)
2. Fix the underlying problem (e.g. add API key, fix code)
3. Remove the `blocked` label from the issue
4. Set the task status back to `new` — the orchestrator picks it up again

### Agent-Reported Blocks
Agents can also report blocks in their JSON response:
- `status: blocked` — waiting for a dependency or missing information
- The agent must provide a `reason` field explaining what happened, what it tried, and what it needs

The reason is persisted in `tasks.yml`, logged to history, appended to `contexts/task-{id}.md`, and posted as a GitHub issue comment.

## Logging & Observability

All state lives under `~/.orchestrator` (the install dir). Logs and runtime files are in the `.orchestrator/` subdirectory within it.

### Log Files

| File | Path | Description |
|---|---|---|
| **Server log** | `.orchestrator/orchestrator.log` | Main loop output: ticks, poll, jobs, gh sync, restarts |
| **Archive log** | `.orchestrator/orchestrator.archive.log` | Previous server sessions (rotated on each `orchestrator serve` start) |
| **Jobs log** | `.orchestrator/jobs.log` | Crontab tick output (when using `orchestrator jobs-install`) |

View the server log:
```bash
orchestrator log          # tail last 50 lines
orchestrator log 200      # tail last 200 lines
```

Or tail it live while the server runs:
```bash
TAIL_LOG=1 orchestrator serve
```

### Per-Task Logs

| File | Path | Description |
|---|---|---|
| **Task context** | `contexts/task-{id}.md` | Appended after each run: timestamp, status, summary, reason, files changed |
| **Task history** | `tasks.yml` `.history[]` | Status transitions with timestamps and notes |
| **Agent output** | `.orchestrator/output-{id}.json` | Structured JSON from the last agent run |
| **Agent prompt** | `.orchestrator/prompt-{id}.txt` | Full system prompt + agent message sent to the agent |
| **Agent response** | `.orchestrator/response-{id}.txt` | Raw stdout from the agent |
| **Agent stderr** | `.orchestrator/stderr-{id}.txt` | Stderr captured from the agent (auth errors, warnings) |
| **Route prompt** | `.orchestrator/route-prompt-{id}.txt` | The prompt sent to the router (for debugging routing decisions) |
| **Failed response** | `contexts/response-{id}.md` | Raw agent output when JSON parsing fails |

### GitHub (if synced)

When GitHub sync is enabled, status updates are also posted as issue comments — including summary, reason, blockers, files changed, and attempt count. Blocked/needs_review tasks tag `@owner` for attention.

### What Gets Logged Where

| Event | Server log | Task context | Task history | GitHub | Per-task files |
|---|---|---|---|---|---|
| Tick/poll cycle | x | | | | |
| Task started | x | | x | | prompt saved |
| Agent completed | x | x | x | x | response + stderr |
| Agent blocked/stuck | x | x | x | x (comment + label) | response + stderr |
| Auth/billing error | x | | x | x (comment + label) | stderr |
| Timeout | x | | x | x (comment + label) | |
| Invalid response | x | x (raw saved) | x | x (comment + label) | response |
| Review result | x | | x | x | |
| Delegation | x | | x | x | |
| Job triggered | x | | | | |
| Config/code restart | x | | | | |

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
| `workflow` | `max_attempts` | Max attempts before marking task as blocked. | `10` |
| `workflow` | `required_skills` | Skills always injected into agent prompts (marked `[REQUIRED]`). | `[]` |
| `workflow` | `disallowed_tools` | Tool patterns blocked via `--disallowedTools`. | `["Bash(rm *)","Bash(rm -*)"]` |
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

## Task Decomposition (Plan Mode)

Complex tasks can be broken down into smaller subtasks before execution. This happens in two ways:

### Automatic (router decides)
The router evaluates task complexity and sets `decompose: true` when a task touches multiple systems, requires many file changes, or has multiple deliverables. The task gets a `plan` label automatically.

### Manual (user decides)
Add the `plan` label when creating a task:
```bash
orchestrator plan "Implement user auth" "Add login, signup, password reset with JWT tokens" "backend"
```

Or add a task with the `plan` label directly:
```bash
orchestrator add "Redesign the API" "..." "plan,backend"
```

### How It Works
1. The agent receives `prompts/plan.md` instead of the execution prompt
2. It reads the codebase, analyzes the task, and returns only delegations (no code changes)
3. Each subtask gets a clear title, detailed body with acceptance criteria, labels for routing, and a suggested agent
4. The parent blocks until all children complete, then resumes with the execution prompt

### Guidelines in the planning prompt
- Each subtask should be completable in a single agent run
- Subtasks are listed in dependency order
- Bodies include specific file paths, function names, and expected behavior
- Prefers 3-7 subtasks (not too granular, not too broad)
- Includes a testing/verification subtask at the end

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
orchestrator gh-project-info
```
To auto-fill the Status field/options into config:
```bash
orchestrator gh-project-info-fix
```

### Pull issues into tasks.yml
```bash
orchestrator gh-pull
```

### Push tasks to GitHub issues
```bash
orchestrator gh-push
```

### Sync both directions
```bash
orchestrator gh-sync
```

### Error Comments & Blocking
When a task fails (any error), the orchestrator:
1. Posts a comment on the linked GitHub issue with the error details
2. Adds a `blocked` label to the issue
3. Sets the task status to `blocked`

The comment includes: error message, agent name, and attempt count. To unblock, fix the issue, remove the `blocked` label, and set the task back to `new`.

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
2. Status field ID + option IDs (or use `orchestrator gh-project-info`):
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

### v0.1.0

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

#### Task Decomposition (Plan Mode)
- New `prompts/plan.md` — planning-only prompt that analyzes tasks and returns delegations without writing code.
- Router gains `decompose` flag — automatically set for complex tasks (multi-system, many files, multiple deliverables).
- `plan` label — manual override to force decomposition. Added via `orchestrator plan` or `orchestrator add "title" "body" "plan"`.
- `run_task.sh` uses planning prompt on first attempt when `plan` label present, switches to execution prompt on retry/rejoin.
- Router prompt updated with decomposition criteria.

#### Background Service (macOS)
- `orchestrator service-install` / `orchestrator service-uninstall` for launchd integration.
- Auto-starts on login, auto-restarts on crash (KeepAlive + 10s throttle).
- Offered during `orchestrator install` on macOS.
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
- `jobs.yml` preserved across `orchestrator install` (rsync exclude).

#### Per-Project Isolation
- Tasks and jobs tagged with `dir` field (project directory).
- `orchestrator init` for per-project setup with optional GitHub configuration.
- `list`, `status`, `dashboard`, `tree`, `next` filter by current project directory.
- `serve` polls all projects globally; `run_task.sh` reads task's `dir` and runs agents in the correct directory.
- GitHub sync runs per-project (iterates unique dirs from tasks).

#### Homebrew
- `brew tap gabrielkoerich/orchestrator && brew install orchestrator` — installs with all dependencies.
- `brew services start orchestrator` — macOS background service.
- Auto-release workflow: tags new versions every Friday using conventional commits, updates formula automatically.

#### Tests
- 28 tests (up from 13), covering: output file reading, stdout fallback, cron matching, job creation, dedup, disable, removal, project config overlay, plan/decompose mode, per-project filtering, init, dir field on jobs.
