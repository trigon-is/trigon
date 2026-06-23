# Contributing to Trigon

Thanks for your interest in Trigon. This is a small, bash-and-Docker project, so
contributing is mostly a matter of editing shell scripts and YAML, running a few
quick checks, and opening a pull request.

## Getting started

1. Make sure you meet the [prerequisites](README.md#prerequisites) (Docker +
   Compose v2, bash, python3, Linux).
2. Fork and clone the repo.
3. Build an image and confirm it launches before changing anything:
   ```bash
   ./build.sh
   ./trigon-up.sh ~/some-project
   ```

## Where things live

The repo is organised around three extension points. To add one, follow the
matching guide rather than wiring it up from scratch:

- **A new provider** → [docs/providers.md](docs/providers.md#adding-a-new-provider)
  (usually just a new `providers/*.yml`)
- **A new agent** → [docs/agents.md](docs/agents.md#adding-a-new-agent)
- **A new mode** → [docs/modes.md](docs/modes.md)

The [architecture overview](docs/trigon-architecture.md) explains how
`trigon-up.sh`, the compose fragments, and the agent wrappers fit together.

## Before you push: run the checks

CI runs on every push and pull request (see `.github/workflows/ci.yml`). Every
check runs locally in seconds and needs no Docker:

```bash
# 1. Static analysis. CI uses --severity=warning; running the default locally
#    is stricter and worth doing.
shellcheck trigon-up.sh build.sh agents/*/wrapper.sh

# 2. Syntax check (parses without executing)
for f in trigon-up.sh build.sh agents/*/wrapper.sh; do bash -n "$f"; done
python3 -m py_compile lib/*.py

# 3. Smoke test
./trigon-up.sh --help

# 4. Test suite (see "Testing changes" below)
python3 -m unittest discover -s tests
bats tests/cli
```

Install the tools with `sudo apt-get install shellcheck bats` (Debian/Ubuntu) or
`brew install shellcheck bats-core` (macOS).

## Shell conventions

- Start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote variable expansions (`"$var"`, `"${arr[@]}"`); prefer `[[ ]]` over `[ ]`.
- Keep `trigon-up.sh`'s section-banner comment style — it's what keeps a long
  script navigable.
- Anything that writes into the user's mounted project (e.g. a generated
  `.mcp.json`) must be cleaned up or restored on exit via the `cleanup` trap.

## Testing changes

The suite lives in [`tests/`](tests/) and runs without Docker:

- **`tests/test_*.py`** — Python unit tests (stdlib `unittest`, no pip) for the
  host-side helpers in `lib/` (provider-YAML parsing, MCP merge).
- **`tests/cli/*.bats`** — functional tests of `trigon-up.sh`: the validation
  guards, and the full provider → env → compose wiring via `--dry-run`.

```bash
python3 -m unittest discover -s tests   # python helpers
bats tests/cli                          # CLI behaviour
```

`--dry-run` resolves everything and prints the command it *would* run, but
starts no container — that's what lets the CLI tests cover the launch path
cheaply. Use it yourself to debug a launch:

```bash
./trigon-up.sh ~/project --provider deepseek --dry-run
```

**When adding a feature**, add a test: a new provider gets a case in
`test_parse_provider.py`; a new flag or guard gets a case in `tests/cli/`.

Some things still need a real container — image contents, the agent actually
talking to a provider, Playwright. For those, build and launch:

```bash
./build.sh --mode security        # if you touched security mode
./trigon-up.sh ~/project --mode security
```

For provider changes, a `--prompt-file` pipeline run is the quickest end-to-end
check. Note in your PR what you tested and how.

## Pull requests

1. Branch off `main` (or `master`) with a short descriptive name.
2. Keep commits focused; write a clear message explaining the *why*, not just
   the *what*.
3. Make sure the local checks pass.
4. Open the PR with a description of the change and how you verified it.

## License

By contributing, you agree that your contributions are licensed under the
project's [Apache-2.0 License](LICENSE).
