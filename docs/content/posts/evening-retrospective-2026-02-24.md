+++
title = "Evening Retrospective 2026-02-24"
date = "2026-02-24"
+++

## Evening Retrospective — 2026-02-24

### Morning Review Outcomes

Task **#319** (morning review, claude) succeeded on attempt 1. It confirmed:
- All Feb 22 issues (#302–306) resolved
- Task #314 (code review) in progress on attempt 6 with claude after 5 opencode failures
- Filed **#321** (jobs_tick.sh not clearing active_task_id on needs_review) and **#322** (code-review job needs agent:claude)

**Both fixes landed today.** #321 was fixed directly by the owner in commit `f4c0c6c`. #322's code change was NOT applied — both jobs.yml files still have `agent: null` (re-filed as #333).

---

### What Was Shipped Today

| Commit | Fix |
|--------|-----|
| `f4c0c6c` | fix(jobs): clear active_task_id when task ends in needs_review/blocked |
| `22c2006` | fix: auto-approve opencode tool permissions and use stdin for prompt |
| `ab93565` | fix: parallel tests + opencode JSON format (#326) |
| `5d4c968` | fix: cycle opencode models on auth errors instead of marking needs_review |
| `fb60ce0` | feat: configurable git author/committer identity per agent |
| `a5ee0cc` | feat: source ~/.path and ~/.functions in runner scripts |
| `3ae115d` | feat: append date to job-created task titles |
| `a65b33f` | fix(tests): startswith match for date-suffixed job titles |

Opencode received 3 separate fixes today (stdin prompt, JSON format, auth cycling). This agent had been the primary failure source all week.

---

### Tasks Completed Today

| Task | Result | Notes |
|------|--------|-------|
| #319 morning-review | ✅ done | claude, 1 attempt |
| #314 code-review | ✅ done | claude, 6 attempts (5 opencode failures) |
| #327 mention response | ✅ done | opencode (kimi-k2-thinking), 3 attempts |

---

### Tasks That Failed

**Dual-scheduler duplicates — the day's biggest problem:**

After `f4c0c6c` cleared `active_task_id` on needs_review, the catch-up mechanism ran for all three jobs simultaneously. Because `serve.sh` runs `jobs_tick.sh` twice per tick (once per project-local jobs.yml, once for `~/.orchestrator/jobs.yml`), **every scheduled job created two tasks**:

| Job | Task A | Task B | Outcome |
|-----|--------|--------|---------|
| morning-review | #324 (global scheduler) | #325 (project-local) | Both needs_review, 4 attempts each |
| test-afternoon | #328 | #329 | Both needs_review |
| evening-retrospective | #330 | #331 (this task) | Both in_progress now |

Tasks #324 and #325 both started at exactly 12:46:45 UTC and failed within 9 seconds with empty response/stderr. The concurrent startup likely caused resource contention. Even after round_robin routed #324 to claude on attempt 3, it still failed instantly — confirming the issue was environmental, not agent-specific.

**Root cause filed as #332**: `serve.sh` should skip the global scheduler when per-project schedulers already ran. The global `~/.orchestrator/jobs.yml` and project-local `.orchestrator/jobs.yml` are currently both active with identical jobs.

---

### Routing Analysis

- **Router**: Running in round_robin mode, bypassing LLM routing. Tasks cycle between agents regardless of task type.
- **Issue**: Round_robin assigned code-review to opencode (5 failures) and kimi (1 failure) before claude succeeded.
- **Fix needed**: code-review-orchestrator job needs `agent: claude` hardcoded (filed as #333).
- **Prompt clarity**: `system.md` and `agent.md` are clear. The issue is routing config, not prompt quality.

---

### Performance

- Service running at v0.56.2, polling every ~45s, two projects
- Worktree cleanup: ~13–22s per project per cycle (within normal range)
- No rate limits, no lock contention observed
- Opencode now cycles models on auth errors instead of marking needs_review — reduces wasteful retries

---

### Issues Filed

| Issue | Priority | Description |
|-------|----------|-------------|
| **#332** | 🔴 HIGH | fix(jobs): skip global scheduler when per-project jobs.yml already processed |
| **#333** | 🟡 MEDIUM | fix(jobs): set agent:claude for code-review-orchestrator in both jobs.yml files |

---

### Tomorrow's Morning Priorities

1. **Fix #332 first** — the dual scheduler is creating 2x tasks for every scheduled job. With 3 jobs, each morning now starts 6 tasks instead of 3, burning agent capacity and creating confusing duplicate issues. Fix: track `FOUND_LOCAL_JOBS` in `serve.sh` and skip global scheduler if any per-project job ran.

2. **Fix #333** — 2 lines in each jobs.yml: `agent: null` → `agent: claude` for code-review. Simple change that prevents the Monday code review from failing again.

3. **Close stale tasks** — issues #324, #325, #328, #329, #330 are all duplicate/failed scheduled jobs that can be closed now that the root cause is understood. _(Flag: do this cleanup manually or in a follow-up task — not a new issue.)_
