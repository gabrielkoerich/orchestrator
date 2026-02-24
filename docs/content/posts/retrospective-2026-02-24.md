+++
title = "Retrospective 2026-02-24"
date = "2026-02-24"
+++

## Evening Retrospective — 2026-02-24

### Morning Review Status

Task #319 (morning review) was created at 11:47 UTC as a catch-up job (missed since 2026-02-22) and is currently running. It started simultaneously with this evening retrospective due to both jobs catching up after being blocked on tasks #287 and #301 ending in `needs_review`.

### What Was Shipped Yesterday (Feb 23)

The owner landed 10 commits directly — a highly productive day:

| PR | Title | Impact |
|---|---|---|
| #318 | feat: async tmux execution — poll.sh no longer blocks | Major: parallel task dispatch now possible |
| #317 | fix: project name in tmux session names | Critical: prevented multi-project collision |
| #316 | Centralize PATH + prevent duplicate job runs | Important: PATH issues fixed in launchd context |
| #313 | Add kimi + minimax + skip complexity in round_robin | Feature: more agent options |
| #311 | fix: multi-project polling and per-project jobs | Bug fix for multi-project setups |

Plus direct pushes: opencode NDJSON parsing, auth/billing fallback, sandbox/worktree fixes, global worktrees path centralization.

### Tasks Completed Since Last Retro

All 5 issues from the 2026-02-22 retrospective were resolved and merged within hours:
- **#302** → closed: `fix(prompts): allow done for comment-only tasks` — ended the in_progress leak
- **#303** → closed: `fix(mentions): auto-close stale mention tasks`
- **#304** → closed: `fix(review): retry review agent once` (tests in PR #309)
- **#305** → closed: `feat(routing): prefer claude for mention tasks`
- **#306** → closed: `fix(mentions): dedup check for closed issues` (PR #308)

### What Failed

**Code review task #314 (6 attempts, still in-flight):**
- Attempts 1–5: opencode via round_robin, all failed with `invalid JSON response` or `missing status`
- Root cause: `agent: null` in jobs.yml + `router.mode: round_robin` → opencode gets assigned; opencode hits permission prompts and produces no JSON
- Auth/billing fallback eventually switched to claude on attempt 6
- Filed #322 to fix by setting `agent: claude` in jobs.yml

**Morning review + evening retro missed Feb 23 entirely:**
- Both tasks ended `needs_review` on Feb 22 (#287, #301)
- `jobs_tick.sh` only clears `active_task_id` on `done` — `needs_review` blocks indefinitely
- Same pattern seen in Feb 20 investigation (#123, which hit max attempts itself)
- Filed #321 to fix: treat `needs_review`/`blocked` same as `done` in jobs_tick.sh

### Root Causes Filed

1. **#321** — `jobs_tick.sh` blocks on needs_review/blocked active tasks (HIGH priority, recurring)
2. **#322** — code-review-orchestrator job needs `agent: claude` in jobs.yml (Medium)

### Prompt and Routing Analysis

- **system.md**: Updated and correct. The fix from #302 (allow `done` for comment-only tasks) is working.
- **route.md**: Clear. Round_robin mode bypasses LLM routing entirely — this is a config choice.
- **agent.md**: Clear. Context enrichment is working well.
- **Router config**: `router.mode: round_robin` is set — this bypasses LLM routing and cycles agents. Appropriate for multi-agent load distribution, but poor for task-type-specific routing. The code review job needs explicit `agent:` to avoid being round-robined to the wrong agent.

### Performance Notes

- Cleanup worktrees scans: ~13 seconds per project per cycle — normal
- Async tmux (PR #318) is a major improvement: poll.sh no longer blocks waiting for running agents
- No API rate limits observed in logs
- No lock contention visible

### What Tomorrow's Morning Review Should Tackle

**Priority 1**: Fix #321 — `jobs_tick.sh` active_task_id not clearing on `needs_review`. This is a recurring issue that has caused missed runs multiple times.

**Priority 2**: Fix #322 — Update `agent: claude` in `code-review-orchestrator` job in `.orchestrator/jobs.yml`. Simple config change, prevents repeated opencode failures.

**Priority 3**: Verify task #314 (code review, attempt 6 with claude) completed successfully and close the issue.
