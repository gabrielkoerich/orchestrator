+++
title = "Evening Retrospective — 2026-02-24"
date = "2026-02-24"
+++

## Evening Retrospective — 2026-02-24

### Today's Fixes (Landed from main)

| Commit | Fix |
|--------|-----|
| `98ebb1a` | fix(jobs): skip global jobs_tick when project-local jobs.yml exists |
| `5d83dfa` | Revert "Run bats with --abort for fail-fast tests" |
| `40a69f2` | Merge branch 'main' — brings #332 and #333 fixes |

The **dual-scheduler issue (#332)** is now fixed. The global `~/.orchestrator/jobs.yml` is skipped when per-project `.orchestrator/jobs.yml` has already run. This eliminates the 2x task duplication that plagued yesterday's scheduled jobs.

Issue **#333** (code-review job needs `agent: claude`) was also closed — both jobs.yml files now have the correct agent setting.

---

### Today's Task Status

| Task | Status | Agent | Notes |
|------|--------|-------|-------|
| #339 | **in_progress** | opencode | Evening retrospective (this task) |
| #333 | ✅ done | — | Fixed jobs.yml agent settings |
| #332 | ✅ done | — | Fixed dual scheduler |

---

### What Worked

1. **Dual-scheduler fix landed** — No more duplicate tasks from job runs
2. **Code-review agent config** — Hardcoded `agent: claude` prevents routing failures
3. **v0.56.5 running** — Clean startup, skills synced, polling at 10s interval
4. **Review agent working** — PR #337 auto-approved and queued for merge

---

### What Failed / Needs Attention

1. **Task #339 (this task)** — Routed to opencode via round_robin but ended in `needs_review`. The catch-up mechanism worked (job created the task), but the agent execution failed.

2. **Catch-up jobs creating duplicates still** — Looking at the log:
   ```
   [jobs] job=evening-retrospective catch-up: missed run since 2026-02-24T18:00:55Z
   [jobs] job=evening-retrospective created task 339
   ```
   The job system created one task (not two!) — this is progress. But the task itself failed.

---

### Prompt Review

Reviewed `prompts/system.md`:
- Clear, comprehensive rules
- Proper JSON output format specified
- Worktree isolation rules explicit
- Branch/PR workflow clear

**No changes needed** — prompts are effective.

---

### Routing Analysis

- Running in **round_robin** mode (bypassing LLM routing)
- This task (#339) got assigned to opencode, but it failed
- For scheduled retrospective tasks, consider hardcoding `agent: claude` since these are planning/writing tasks that Claude handles well

---

### Performance

- Polling every 10s (fast)
- Worktree cleanup: 13–22s per project
- No rate limits observed
- Review agent working correctly

---

### Tomorrow's Priorities

1. **Investigate why #339 failed** — Check opencode stderr, ensure agent can run retrospective tasks

2. **Hardcode agent for retrospective jobs** — Add `agent: claude` to evening-retrospective and morning-review jobs in both jobs.yml files

3. **Close stale issues** — #324, #325, #328, #329, #330 are all duplicate/failed from the dual-scheduler era

4. **Run tests** — Verify `bats tests` passes before marking done

---

### Flag for Follow-up

- The catch-up mechanism created task 339 successfully, but the agent failed. Need to understand why opencode couldn't complete this retrospective task.
