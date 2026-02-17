# Orchestrator — Agent & Developer Notes

You are an autonomous orchestrator. You should look for ways to make yourself better, make the workflow better for your agents, and learn every day.

## Upgrading

```bash
brew update && brew upgrade orchestrator
```

## Restarting the service

```bash
orchestrator stop && orchestrator start
```

Or equivalently:
```bash
brew services restart orchestrator
```

## Unblocking tasks

```bash
orchestrator tasks unblock all
```

## Logs

- Service log: `~/.orchestrator/.orchestrator/orchestrator.log`
- Brew stdout: `/opt/homebrew/var/log/orchestrator.log` (startup messages only)
- Brew stderr: `/opt/homebrew/var/log/orchestrator.error.log`

## Complexity-based model routing

The router assigns `complexity: simple|medium|complex` instead of specific model names. The actual model is resolved per agent from `config.yml`:

```yaml
model_map:
  simple:
    claude: haiku
    codex: gpt-5.1-codex-mini
  medium:
    claude: sonnet
    codex: gpt-5.2
  complex:
    claude: opus
    codex: gpt-5.3-codex
  review:
    claude: sonnet
    codex: gpt-5.2
```

See `model_for_complexity()` in `scripts/lib.sh`.

## Specs & Roadmap

See [specs.md](specs.md) for architecture overview, what's working, what's not, and improvement ideas.

## Release pipeline

1. Push to `main`
2. CI runs tests, auto-tags (semver from conventional commits)
3. GitHub release created, Homebrew tap formula updated automatically
4. `brew upgrade orchestrator` picks up the new version
5. `orchestrator stop && orchestrator start` to load new code

**Do NOT manually edit the tap formula** — the CI pipeline handles it. The `Formula/orchestrator.rb` in this repo is a local reference copy, not the real tap.

## Task status semantics

- **`blocked`** — waiting on a dependency (parent blocked on children, missing worktree/dir)
- **`needs_review`** — requires human attention (max attempts, review rejection, agent failures, retry loops, timeouts)
- `mark_needs_review()` sets `needs_review`, NOT `blocked`
- Only parent tasks waiting on children should be `blocked`
- `poll.sh` auto-unblocks parent tasks when all children are done

## Agent sandbox

Agents run in worktrees, NOT the main project directory. The orchestrator enforces this:

1. **Prompt-level**: system prompt tells agents the main project dir is read-only
2. **Tool-level**: dynamic `--disallowedTools` blocks Read/Write/Edit/Bash targeting the main project dir
3. Config: `workflow.sandbox: false` to disable (not recommended)

## Codex sandbox config

Codex runs with `--full-auto` + network access enabled by default. Configurable:

```yaml
# In config.yml or .orchestrator.yml
agents:
  codex:
    sandbox: full-auto  # full-auto | workspace-write | danger-full-access | none
```

Or per-run: `CODEX_SANDBOX=danger-full-access orchestrator task run 5`

Modes:
- `full-auto` (default) — filesystem sandboxed, network enabled
- `workspace-write` — same sandbox, explicit mode
- `danger-full-access` — no sandbox (for tasks needing bun, solana-test-validator, etc.)
- `none` — bypasses all Codex sandboxing (orchestrator is the sandbox)
