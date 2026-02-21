# Contributing

Thanks for contributing to Orchestrator!

## Development setup

Prereqs (macOS/Homebrew):

```bash
brew install yq jq just python@3 ripgrep fd bats-core
# Optional (used in Beads/`bd` experiments): brew install bd
```

Clone + sanity check:

```bash
git clone https://github.com/gabrielkoerich/orchestrator.git
cd orchestrator
just            # list available commands
```

## Running tests

Tests use the `bats` framework:

```bash
bats tests/orchestrator.bats   # main test file
# bats tests                  # run all tests
```

## Commit message conventions

Use Conventional Commits:
- `feat:` new feature (minor bump)
- `fix:` bug fix (patch bump)
- `docs:` documentation only
- `chore:` maintenance/refactor

## PR workflow

- Branch from `main` and keep changes focused.
- Open a PR early; keep it small and easy to review.
- Prefer **squash merge** on GitHub.

```bash
git fetch origin
git checkout -b my-branch origin/main
git commit -m "docs: add contributing guide"
git push -u origin my-branch
```

