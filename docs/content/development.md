+++
title = "Development"
description = "Contributing, testing, and release pipeline"
weight = 11
+++

## Setup

```bash
git clone https://github.com/gabrielkoerich/orchestrator.git
cd orchestrator
bats tests          # run tests
just                # list available commands
```

Requires: `yq`, `jq`, `just`, `python3`, `rg`, `fd`, `bats`.

## Tests

Tests use the [bats](https://github.com/bats-core/bats-core) framework:

```bash
bats tests                              # run all tests
bats tests --filter "review"            # run matching tests
bats tests/orchestrator.bats            # run specific file
```

All tests mock external tools (`gh`, `codex`, `claude`) to prevent real API calls. Test setup creates a temporary directory with a git repo, tasks.yml, and config.yml.

## Release Pipeline

1. Push to `main` → CI runs tests
2. Auto-tag from conventional commits (`feat:` = minor, `fix:` = patch)
3. Generate changelog
4. Create GitHub release
5. Update `gabrielkoerich/homebrew-tap` Formula with new URL + SHA256
6. `brew upgrade orchestrator` picks up the new version

### Conventional Commits

Use prefixes in commit messages:
- `feat:` — new feature (bumps minor version)
- `fix:` — bug fix (bumps patch version)
- `chore:` — maintenance (no version bump)
- `docs:` — documentation (no version bump)

## Project Structure

```
scripts/
  lib.sh          — shared helpers (logging, locking, yq wrappers, GitHub API)
  serve.sh        — main loop (poll, jobs, gh sync)
  poll.sh          — finds and runs pending tasks
  run_task.sh     — runs a single task (route → agent → parse → review)
  route_task.sh   — routes tasks via LLM
  gh_push.sh      — pushes task updates to GitHub
  gh_pull.sh      — imports GitHub issues
  gh_sync.sh      — bidirectional sync
  add_task.sh     — creates tasks
  output.sh       — shared formatting (tables, sections)
  normalize_json.py — JSON extraction, tool history, token usage
  cron_match.py   — cron expression matcher
prompts/
  system.md       — system prompt
  agent.md        — execution prompt
  plan.md         — planning/decomposition prompt
  route.md        — routing prompt
  review.md       — review agent prompt
tests/
  orchestrator.bats — test suite
docs/
  content/        — documentation pages (Zola site)
  templates/      — Zola HTML templates
  config.toml     — Zola config
```
