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
3. GitHub release created, Homebrew tap formula updated
4. `brew upgrade orchestrator` picks up the new version
5. `orchestrator stop && orchestrator start` to load new code
