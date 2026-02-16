# Agent Workflow

How the orchestrator runs tasks end-to-end.

## Full Development Cycle

```
Issue → Branch + Worktree → Agent works → Push → PR → Review → Merge → Cleanup
```

1. **Issue** — created via `orchestrator task add`, `gh_pull`, or `jobs_tick`
2. **Branch + Worktree** — orchestrator creates via `gh issue develop` + `git worktree add`
3. **Agent works** — runs inside worktree, edits files, commits changes
4. **Push** — orchestrator pushes the branch after agent finishes
5. **PR** — agent creates with `gh pr create --base main` and `Closes #N`
6. **Review** — Codex auto-reviews on PR open (or `@codex review`)
7. **Fix + Reply** — fix review findings, reply to each comment, resolve threads
8. **Merge** — squash merge with conventional commit prefix (`feat:` / `fix:`)
9. **Release** — CI auto-tags, generates changelog, creates GitHub release, updates Homebrew
10. **Cleanup** — (TODO) orchestrator detects merged PR, removes worktree + local branch

## Task Lifecycle

```
new → routed → in_progress → done
                           → blocked
                           → needs_review
```

- **new**: task created (via `add`, `gh_pull`, or `jobs_tick`)
- **routed**: LLM router assigned agent, model, profile, skills
- **in_progress**: agent is running
- **done**: agent completed, files committed, branch pushed
- **blocked**: agent hit a blocker or crashed
- **needs_review**: agent needs human help

## Poll Loop

`serve.sh` ticks every 10s:

1. `poll.sh` — finds `new`/`routed` tasks, runs them in parallel (up to `POLL_JOBS=4`)
2. `poll.sh` — detects stuck `in_progress` tasks (no lock held, stale >30min), resets to `new`
3. `poll.sh` — checks blocked parents: if all children are `done`, unblocks parent
4. `jobs_tick.sh` — checks cron schedules, creates tasks for due jobs
5. `gh_sync.sh` — pulls issues from GitHub, pushes task updates back (every 60s)

## Worktrees

The orchestrator creates worktrees before launching agents. Agents do NOT create worktrees themselves.

**When a worktree is created:**
- Task has a linked GitHub issue (`GH_ISSUE_NUMBER` is set)
- Task is NOT a decompose/planning task (`decompose: false`)

**When no worktree is created:**
- No GitHub issue linked (e.g. chat tasks, local cron jobs)
- Task is a planning/decompose task

**Worktree path:** `~/.worktrees/<project>/gh-task-<issue>-<slug>`

**Steps:**
1. `gh issue develop <issue> --base main --name <branch>` — registers branch with GitHub
2. `git branch <branch> main` — creates branch from main
3. `git worktree add ~/.worktrees/<project>/<branch> <branch>` — creates worktree
4. Agent runs inside the worktree directory (`PROJECT_DIR` is set to worktree)

**After agent finishes:**
- Orchestrator pushes the branch (`git push -u origin <branch>`) if there are unpushed commits
- Agent should NOT run `git push` itself

## Agent Invocation

`run_task.sh` runs the agent:

```bash
claude -p \
  --model <model> \
  --permission-mode acceptEdits \
  --allowedTools "Write" \
  --disallowedTools "Bash(rm *)" \
  --output-format json \
  --append-system-prompt <system_prompt> \
  <agent_message>
```

- `--permission-mode acceptEdits` — agent can edit files without prompts
- `--allowedTools "Write"` — agent can write the output JSON file
- `--output-format json` — structured response for parsing
- Output file: `~/.orchestrator/.orchestrator/output-<task_id>.json`

## Agent Output

The agent writes a JSON file with:

```json
{
  "status": "done|in_progress|blocked|needs_review",
  "summary": "what was done",
  "reason": "why blocked/needs_review (empty if done)",
  "accomplished": ["list of completed items"],
  "remaining": ["list of remaining items"],
  "blockers": ["list of blockers"],
  "files_changed": ["list of modified files"],
  "needs_help": false,
  "agent": "claude",
  "model": "claude-sonnet-4-5-20250929",
  "delegations": [{"title": "...", "body": "...", "labels": [], "suggested_agent": "codex"}]
}
```

**Validation:**
- `status` is required — if missing, task goes to `needs_review`
- `done` with no `files_changed` and non-empty `remaining` = agent didn't actually finish
- `delegations` create child tasks automatically

## Routing

`route_task.sh` sends task title+body to an LLM and gets back:

```json
{
  "executor": "claude",
  "model": "sonnet",
  "decompose": false,
  "reason": "why this agent/model",
  "profile": {
    "role": "DeFi Protocol Engineer",
    "skills": ["Solana", "Anchor"],
    "tools": ["Bash", "Edit", "Read"],
    "constraints": ["audit with sealevel attacks"]
  },
  "selected_skills": ["solana-best-practices"]
}
```

- `decompose: true` — task gets broken into subtasks before execution
- `decompose: false` — task runs directly
- Skills are loaded from `~/.orchestrator/skills/` (synced from registries)

## GitHub Sync

**Pull** (`gh_pull.sh`):
- Reads open issues from the repo
- Creates/updates local tasks in `tasks.yml`
- Maps issue labels to task fields

**Push** (`gh_push.sh`):
- Posts comments on GitHub issues with agent results
- Includes: agent badge, summary, accomplished/remaining lists, metadata (duration, tokens, model)
- Applies labels (e.g. `blocked` label when task is blocked)
- Content-hash dedup prevents duplicate comments
- Closes issues automatically when task status is `done` (configurable via `auto_close`)

## PR Review Workflow

After an agent creates a PR:

1. Codex auto-reviews (triggered on PR open or `@codex review` comment)
2. Fix findings, reply to each review comment:
   ```bash
   gh api repos/OWNER/REPO/pulls/PR/comments/ID/replies -X POST -f body="Fixed — ..."
   ```
3. Resolve review threads:
   ```bash
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "ID"}) { thread { isResolved } } }'
   ```
4. Squash merge with conventional commit prefix (`feat:` = minor, `fix:` = patch)

## Stuck Task Recovery

`poll.sh` detects stuck tasks:

1. **No agent assigned** — task stuck `in_progress` without an agent → set to `blocked`
2. **Dead agent** — task has agent but no lock file and `updated_at` is older than `stuck_timeout` (default 30min) → reset to `new`

## Retry / Unblock

```bash
orchestrator task retry <id>       # reset any task to new
orchestrator task unblock <id>     # reset a blocked task to new
orchestrator task unblock all      # reset all blocked tasks to new
```

## Max Attempts

Default: 10 attempts per task (configurable via `config.yml`). After max attempts, task goes to `blocked` with error. Retry loop detection: if the same error repeats 3 times, task goes to `needs_review` instead of retrying.

## Context Enrichment

The agent prompt includes:

| Context | Source |
|---------|--------|
| Task title, body, labels | `tasks.yml` |
| Parent task context | parent's summary + accomplished |
| Previous attempt history | last 5 history entries |
| Last error | `last_error` field |
| GitHub issue comments | `gh api` (last 10 comments) |
| Project instructions | `.orchestrator.yml` or `CLAUDE.md` |
| Skills documentation | `SKILL.md` files from selected skills |
| Repository tree | `git ls-tree` (file listing) |
| Git diff | uncommitted changes (on retry) |

## Cron Jobs

```bash
orchestrator job add "0 9 * * *" "Daily report" "body" "labels"
orchestrator job add --type bash --command "echo hello" "@hourly" "Ping"
orchestrator job list
orchestrator job enable <id>
orchestrator job disable <id>
```

Two job types:
- **task** (default): creates a task that goes through routing → agent execution
- **bash**: runs a shell command directly, no LLM involved

Jobs are checked every tick. When a schedule matches, a task is created (or command run). Jobs skip if a previous task from the same job is still in-flight.

## CLI Namespaces

```bash
orchestrator task status|list|tree|add|plan|route|run|next|poll|retry|unblock|agent|stream|watch|unlock
orchestrator service start|stop|restart|info|install|uninstall
orchestrator gh pull|push|sync
orchestrator project info|create|list
orchestrator job add|list|remove|enable|disable|tick
orchestrator skills list|sync
```

Top-level commands: `init`, `chat`, `dashboard`, `log`, `start`, `stop`, `restart`, `info`, `agents`.

## Chat

```bash
orchestrator chat
```

Interactive mode with readline support (arrow keys, persistent history). Talk to the orchestrator, add tasks, check status. Runs in the current `PROJECT_DIR`. Chat tasks don't have GitHub issues, so no worktrees are created.

## Release Pipeline

1. Push to `main` → CI runs tests
2. Auto-tag from conventional commits (`feat:` = minor, `fix:` = patch)
3. Generate changelog (conventional commits + GitHub auto-generated PR notes)
4. Create GitHub release
5. Update `gabrielkoerich/homebrew-tap` Formula with new URL + sha256
6. `brew upgrade orchestrator` picks up the new version
