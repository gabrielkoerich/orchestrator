+++
title = "Morning Review — 2026-02-24"
date = "2026-02-24"
+++

## Jobs System Review

### Problem: Jobs Blocked Since Feb 22

The `morning-review` and `evening-retrospective` jobs had not fired since
2026-02-22. Root cause: both had an `active_task_id` pointing to tasks 287
and 301 respectively, both stuck in `needs_review`. The jobs tick skips a
job if its active task hasn't reached `done` — so a `needs_review` outcome
permanently blocks the next scheduled run.

**Fix applied**: cleared both `active_task_id` fields manually and ran the
tick to trigger catch-up. Tasks 319 (morning) and 320 (evening) were created.

### Root Cause Still Open

`jobs_tick.sh` only clears `active_task_id` on `done`. Tasks ending in
`needs_review` or `blocked` permanently block the job until manual
intervention. Issue #321 filed to fix this.

### Other Fixes Applied Today

| Change | Details |
|--------|---------|
| Date in task titles | Job-created tasks now include the run date: `Daily morning review (2026-02-24)` |
| Post filename convention | Morning → `morning-review-YYYY-MM-DD.md`, Evening → `evening-retrospective-YYYY-MM-DD.md` |
| Prompts read latest post | Both job prompts now read `./docs/content/posts` for context |
| Async tmux | `poll.sh` no longer blocks on running agent sessions (#318) |
| Tmux session naming | Sessions now include project name to avoid cross-project collisions (#317) |

### Current Task Status

| ID  | Status      | Agent   | Title |
|-----|-------------|---------|-------|
| 322 | routed      | kimi    | fix(jobs): set agent:claude for code-review-orchestrator |
| 321 | routed      | opencode | fix(jobs): clear active_task_id on needs_review/blocked |
| 320 | in_progress | claude  | Daily evening retrospective (catch-up Feb 23) |
| 319 | in_progress | claude  | Daily morning review (catch-up Feb 23) |
| 314 | done        | claude  | Code review: orchestrator |

### Tonight

Evening retrospective fires at 18:00 UTC with the updated prompt and will
save to `evening-retrospective-2026-02-24.md`.
