+++
title = "GitHub Sync"
description = "Two-way sync between tasks.yml and GitHub Issues"
[extra]
weight = 7
+++

Sync tasks to GitHub Issues using `gh`. The orchestrator supports two-way sync, project boards, error comments, and rate-limit backoff.

## Setup

1. Install and authenticate:
```bash
gh auth login
```

2. Configure in `config.yml`:
```yaml
gh:
  enabled: true
  repo: "owner/repo"
  sync_label: "sync"       # only sync tasks/issues with this label (empty = all)
```

3. Optionally set up a GitHub Project v2:
```bash
orch project info --fix     # auto-fills project field/option IDs into config
```

## Commands

```bash
orch gh pull    # import GitHub issues into tasks.yml
orch gh push    # push task updates to GitHub issues
orch gh sync    # both directions
```

The background server (`orch start`) runs `gh sync` every 60 seconds automatically.

## Pull (Issues → Tasks)

`gh_pull.sh` reads open issues from the repo and creates/updates local tasks:
- Maps issue labels to task fields
- Preserves existing task state (won't overwrite local changes)
- Handles paginated API responses
- Skips issues with `no_gh` or `local-only` labels

## Push (Tasks → Issues)

`gh_push.sh` posts structured comments on GitHub issues:
- **Agent badges**: 🟣 Claude, 🟢 Codex, 🔵 OpenCode
- **Metadata table**: status, agent, model, attempt, duration, tokens, prompt hash
- **Sections**: errors & blockers, accomplished, remaining, files changed, agent activity
- **Tool activity**: tool call counts by type with collapsed failed command details
- **Collapsed sections**: stderr output and full prompt (with hash)
- **Content-hash dedup**: identical comments not re-posted

### Labels

- `status:<status>` label synced from task status
- `blocked` (red) label applied when task is blocked, removed when unblocked
- `scheduled` and `job:{id}` labels for job-created tasks
- When task is `done`, `auto_close` controls whether to close the issue

### Error Comments

When a task fails, the orchestrator:
1. Posts a structured comment with error details
2. Adds a red `blocked` label
3. Tags `@owner` for attention

## Backoff

When GitHub rate limits or abuse detection triggers, the orchestrator sleeps and retries:

```yaml
gh:
  backoff:
    mode: "wait"         # "wait" (default) or "skip"
    base_seconds: 30     # initial backoff duration
    max_seconds: 900     # maximum backoff duration
```

The backoff is shared across all GitHub operations — a single rate limit event pauses all GitHub writes.

## Projects (Optional)

Link tasks to a GitHub Project v2 board:

```yaml
gh:
  project_id: "PVT_..."
  project_status_field_id: "PVTSSF_..."
  project_status_map:
    backlog: "option-id-1"
    in_progress: "option-id-2"
    review: "option-id-3"
    done: "option-id-4"
```

Discover IDs automatically:
```bash
orch project info        # show current project field/option IDs
orch project info --fix  # auto-fill into config
```

## Owner Feedback

When the repo owner (or `workflow.review_owner`) comments on a GitHub issue or PR linked to a completed task, the orchestrator detects the feedback and re-activates the task:

1. During `gh pull`, tasks with status `done`, `in_review`, or `needs_review` are checked for new owner comments
2. If new comments are found, the task is reset to `routed` (keeping its agent assignment)
3. The feedback is appended to the task context so the agent sees it on re-run
4. The `last_error` field is set to the feedback text for visibility

This allows the owner to steer agents by commenting on GitHub — no manual task editing needed. The `gh_last_feedback_at` field prevents re-processing the same comment.

## Notes

- The repo is resolved from `config.yml` or `gh repo view`
- Issues are created for tasks without `gh_issue_number`
- Tasks with `no_gh` or `local-only` labels are not synced
- Task status is synced via `status:<status>` issue labels
- Agents never call GitHub directly; the orchestrator handles all API calls so it can back off safely
