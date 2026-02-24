+++
title = "Evening Retrospective — 2026-02-24"
date = "2026-02-24"
+++

## Evening Retrospective — 2026-02-24

### Morning Review Recap

The morning review (task #319, completed successfully) identified and tracked
two active bugs: #321 (jobs_tick not clearing `active_task_id` on `needs_review`)
and #322 (code-review job not pinned to claude). Both have since been fixed.

The morning review also documented several architectural improvements made today:
date-stamped task titles, updated job prompt file naming conventions, async
tmux dispatch, and project-scoped tmux session names.

---

### What Was Shipped Today

| Commit | Fix | Impact |
|--------|-----|--------|
| `f4c0c6c` | `fix(jobs): clear active_task_id on needs_review/blocked` | **HIGH** — recurring issue that caused missed scheduled runs |
| `5d4c968` | `fix: cycle opencode models on auth errors` | Opencode model cycling instead of permanent failure |
| `fb60ce0` | `feat: git author/committer identity configurable` | Commits now attributed correctly per-agent |
| `a5ee0cc` | `feat: source ~/.path and ~/.functions in runners` | PATH issues in launchd context resolved |
| `22c2006` | `fix: auto-approve opencode tool permissions` | Opencode no longer hangs on permission prompts |
| `ab93565` | `fix: revert parallel tests, fix CI` | CI back to stable serial `bats tests` |
| `a65b33f` | `fix(tests): startswith for date-suffixed job titles` | Test handles date-appended titles correctly |
| `3ae115d` | `feat: append date to job-created task titles` | Tasks now clearly timestamped |

**Current version**: v0.56.2

---

### What Completed Successfully

| Task | Agent | Notes |
|------|-------|-------|
| #319 (morning review catch-up) | claude | Done ✓ — full post written to docs |
| #327 (mention handler) | opencode (kimi-k2-thinking) | Responded to @orchestrator mention on #319, linked both posts |
| #314 (code review orchestrator) | claude | Done ✓ — completed after 6 attempts (switch from opencode) |
| #321 (fix jobs_tick) | opencode | Done ✓ — closed, fix committed to main |
| #322 (code-review job agent) | kimi | Done ✓ — closed, jobs.yml updated |

---

### What Failed and Why

#### Tasks 324 (morning review) + 325 (evening retro catch-up) — `needs_review` after 4 attempts

Both were created simultaneously at 12:46 UTC as catch-up jobs. Root cause chain:

1. **Attempt 1** (both tasks, parallel): Claude returned 0 bytes in ~5s with exit=0. Likely: Claude Max hourly limit was already exhausted from the earlier concurrent task run (tasks 319 + 320 ran in parallel at 11:47 UTC).
2. **Attempt 2**: Response file contained `{"is_error":true,"result":"You've hit your limit · resets 1pm (America/Sao_Paulo)"}` — Claude returned exit=0 with a rate-limit JSON envelope.
3. **Critical gap**: `is_usage_limit_error()` in `scripts/lib.sh` does NOT match `"hit your limit"`. Pattern: `limit (?:reached|exceeded)` — requires "reached" or "exceeded" after "limit". Claude's message says "hit your limit" which doesn't match.
4. **Result**: Instead of rerouting to opencode (graceful), the task marked `needs_review` (permanent failure).
5. **Attempt 3-4**: Same rate limit, same miss. On attempt 4, routed to opencode — but opencode.json format was broken in v0.56.0 (fixed in v0.56.2 by adding `| yq -o=json -`). SIGPIPE error.

#### Tasks 328 + 329 (test-afternoon job) — `crashed (exit=141)` × 3 times

- Job was a test job created by the owner at 11:55 UTC with `dir: ""`.
- Empty `dir` → orchestrator resolves project dir from running script path → `/opt/homebrew/Cellar/orchestrator/0.56.x/libexec` → resolves to `/opt/homebrew`.
- Worktree created under `/opt/homebrew` (a Homebrew prefix, not a git repo in the expected sense).
- Exit 141 = SIGPIPE — broken pipe when writing to the runner pipeline.
- This is a one-off test job (schedule: `0 14 24 2 *` = 2pm Feb 24 only). Not a recurring concern, but `dir: ""` handling is fragile.

---

### Root Cause Analysis

#### Primary finding: `is_usage_limit_error()` missing Claude's "hit your limit" pattern

**File**: `scripts/lib.sh:370`

Current pattern:
```
429|too many requests|rate_limit|usage_limit|quota|insufficient_quota|exceeded_quota|limit (?:reached|exceeded)|overloaded_error|service overloaded
```

Missing: Claude's actual message: `"You've hit your limit · resets 1pm (America/Sao_Paulo)"`

**Effect**: Claude Max Pro hourly rate limit hits are misidentified as "invalid JSON" → `needs_review` instead of rerouting to opencode. This has caused multiple scheduled task failures across Feb 22–24.

**Fix**: Add `hit your limit|you.ve hit` to the pattern in `is_usage_limit_error()`.

---

### Prompt and Routing Assessment

**system.md** (52 lines): Clear and correct. The `done` status allowed for comment-only tasks (from #302) is working. No changes needed.

**agent.md** (53 lines): Works well. Context enrichment (retry history, prior runs, git diff) is effective — claude consistently picks up where it left off.

**route.md** (49 lines): Not actively used — `router.mode: round_robin` bypasses LLM routing entirely. The round_robin picks opencode (only enabled agent) for most tasks, but jobs with explicit `agent: claude` correctly use claude. Routing logic is correct; the real issue is the usage limit fallback.

**round_robin config**: `disabled_agents: [claude, codex, kimi, minimax]` — only opencode is in the pool. When claude is used (via explicit job config) and hits a rate limit, `reroute_on_usage_limit()` tries to pick a fallback from the same disabled list and fails. This is expected behavior — the real fix is detecting the rate limit pattern correctly so rerouting fires.

---

### Performance Notes

- Async tmux dispatch (PR #318) is working well — no log evidence of blocking.
- No API rate limits from GitHub observed.
- No lock contention visible in logs.
- Worktree cleanup scans: ~11s per project per cycle (normal).
- Two evening retro tasks (330 + 331) were created this evening — parallel creation race. The `active_task_id` tracking in jobs.yml shows `331`, meaning task 330 is orphaned. Task #331 is the active one.

---

### Open Issues to Carry Forward

**Stale/orphaned issues to flag (not file tasks for):**
- Tasks 324, 325, 328, 329 are all `needs_review` or stuck. They represent failed historical runs — safe to leave as-is since the jobs will fire again tomorrow with fixed code.
- Task #331 is in_progress (this evening's retro, parallel run). Will self-resolve.

---

### Tomorrow's Morning Review Priority

**#1 — File and fix: `is_usage_limit_error()` missing "hit your limit" pattern** (HIGH)

This is the single most impactful bug. Every time the Claude Max hourly limit triggers (common when multiple jobs fire simultaneously), the orchestrator misclassifies it as an invalid JSON error and marks `needs_review` instead of rerouting. A one-line pattern addition in `scripts/lib.sh` would prevent recurring morning/evening review failures.

Fix: add `hit your limit|you.ve hit` to the `rg -qi` pattern in `is_usage_limit_error()`.

**#2 — Verify task #331 completes** (LOW)

Both tasks #330 and #331 were created this evening for the same job run. Task #331 is the `active_task_id` per jobs.yml. Confirm it reaches `done` status. If not, retry manually with `orchestrator task retry 331`.
