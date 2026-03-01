+++
title = "Evening Retrospective — 2026-02-27"
date = "2026-02-27"
+++

## Evening Retrospective — 2026-02-27

### Today's Fixes (from git log)

| Commit | Description |
|--------|-------------|
| `c8d91de` | fix(route): exit 1 when router fails to signal error to callers |
| `ea6ef79` | fix(backend): return 1 for invalid IDs in db_task_field (#420) |
| `ffcaaa2` | fix: add error handling for empty/missing PR title in create-pr.sh (#419) |
| `9453fe6` | fix(docs): add missing front matter closing delimiter in morning review post (#414) |
| `a448aee` | test: add comprehensive test coverage for critical scripts |
| `065c1bf` | fix(cleanup): handle gh errors vs no-merged-pr in cleanup_worktrees.sh (#403) |
| `ed1b56c` | fix(run_task): move _gh_ensure_repo out of subshell in detect_retry_loop (#405) |
| `a936f89` | fix(backend): quote variable to prevent word splitting in label validation (#404) |

**Major improvements today:**
- **Router error handling** — Fixed `route_task.sh` to exit 1 when router fails (was silently succeeding)
- **Backend robustness** — Fixed error handling for invalid IDs in `db_task_field`
- **PR creation safety** — Added validation for empty/missing PR titles in `create-pr.sh`
- **Test coverage** — Added comprehensive tests for critical scripts
- **Cleanup reliability** — Fixed `cleanup_worktrees.sh` to distinguish gh errors from "no merged PRs"
- **Retry loop detection** — Fixed subshell variable scoping bug in `detect_retry_loop`
- **Label validation** — Fixed unquoted variable causing word splitting issues

---

### Current Task Status

| Status | Count |
|--------|-------|
| new | 0 |
| routed | 0 |
| in_progress | 2 |
| needs_review | 4 |
| done | 63 |

**In Progress:**
- **#421** (opencode) — This evening retrospective task
- **#418** (kimi) — Fix route_task.sh exit code — **recovered from stuck state (1848s)**

**Needs Review (pattern: agent response issues):**
- **#376** (claude) — Add test coverage for gh_mentions.sh — **6 attempts, invalid JSON responses**
- **#381** (opencode) — Fix agent runner bugs — **5 attempts, missing status field**
- **#382** (kimi) — Fix non-atomic sidecar writes — **needs_review**
- **#402** (kimi) — Add test coverage for jobs_tick.sh — **in_progress**

---

### What Went Well

1. **8 commits merged today** — All targeted fixes for real bugs identified in recent reviews

2. **Poll recovery working** — Task #418 was stuck for 1848s (~31 minutes) and was automatically recovered by poll

3. **Morning review completed** — Issue #407 closed successfully with analysis and recommendations

4. **Backend fixes landed** — PRs #420, #419, #414, #403, #405, #404 all merged — significant reliability improvements

5. **Evening retrospective job fired correctly** — Catch-up mechanism created task #421 at 21:02:34Z

---

### What Failed / Needs Attention

1. **Task #376 stuck in retry loop** — 6 attempts with claude, all failing with "invalid YAML/JSON" responses. Pattern:
   - Attempt 1: claude rate limited, rerouted to opencode
   - Attempts 2-6: claude with model `opencode/glm-5-free` — all invalid JSON
   - **Root cause**: Model `opencode/glm-5-free` may not support JSON output properly

2. **Task #381 stuck in retry loop** — 5 attempts with opencode, all failing with "missing status":
   - First attempt succeeded (commit 7c3b8a6) but status was `done`
   - Subsequent attempts all fail to produce valid JSON with status field
   - **Root cause**: opencode with `gpt-5-mini` not consistently returning valid JSON

3. **Agent response validation** — Multiple tasks failing because agents return malformed JSON or missing required fields. This is a systemic issue affecting reliability.

---

### Prompt Effectiveness

Reviewed `prompts/system.md` and `prompts/route.md`:

- **System prompt** — Clear workflow rules, good JSON schema definition
- **Route prompt** — Good complexity guidance, proper skill selection

**Issue identified**: The prompts are clear, but some models (especially `opencode/glm-5-free` and possibly `gpt-5-mini`) are not consistently following the JSON output format. This suggests:

1. Models may need stronger JSON enforcement
2. Some models may not support `--output-format json` properly
3. Fallback parsing (stdout extraction) may be catching incomplete responses

**Recommendation**: Review which models actually support structured JSON output and adjust routing accordingly.

---

### Routing Analysis

- **Round-robin mode** active — Tasks distributed across agents
- **Claude rerouting** — Task #376 hit claude rate limit and was rerouted to opencode successfully
- **Model selection issues**:
  - `opencode/glm-5-free` assigned to claude task — this model appears incompatible with claude's JSON output expectations
  - `gpt-5-mini` used for opencode — producing inconsistent JSON

**Root cause**: The model_map in config.yml may be routing tasks to models that don't support the required output format for their assigned agent.

---

### Performance

- **Worktree cleanup**: ~13-22s per project (normal)
- **Poll interval**: ~45s between ticks
- **Service**: v0.56.32 running cleanly
- **Rate limits**: Claude hit rate limit once (task #376), successfully rerouted

**Issues observed**:
- Task #418 stuck for 1848s before recovery
- Multiple tasks in retry loops with JSON parsing failures

---

### Tomorrow's Priorities

1. **Fix model/agent compatibility** — The root cause of #376 and #381 failures is model selection:
   - `opencode/glm-5-free` should not be used with claude (expects different output format)
   - Review model_map configuration for all agents
   - Ensure models support JSON output for their assigned agent

2. **Unblock stuck tasks** — Reset #376 and #381 to `new` after fixing model config:
   - #376: Assign to claude with a proper claude-compatible model
   - #381: Assign to opencode with a model known to work (gpt-5-mini worked on attempt 1)

3. **Add JSON validation** — Consider adding pre-flight JSON validation or stronger model constraints

4. **Close completed tasks** — Several tasks marked done but issues still open:
   - #390 (marked done in log but issue still open)
   - #417 (marked done)

---

### Flag for Follow-up

- **Model compatibility matrix** — Document which models work with which agents
- **JSON output enforcement** — Some models ignore `--output-format json`; need fallback validation
- **Retry loop detection** — Tasks #376 and #381 have 6 and 5 attempts respectively — should have been blocked earlier
- **Task #418** — Investigate why kimi got stuck for 31 minutes (agent startup issue?)

---

### Morning Review Carry-Forward

From #407 (today's morning review):
- ✅ Multiple backend fixes landed (all the PRs mentioned were merged)
- ⚠️ Model compatibility issues identified — need to address
- ⚠️ Task #376 still failing — was flagged, still needs fix

(End of file)
