# Trigon

[![CI](https://github.com/trigon-is/trigon/actions/workflows/ci.yml/badge.svg)](https://github.com/trigon-is/trigon/actions/workflows/ci.yml) ![License](https://img.shields.io/badge/license-Apache--2.0-blue) ![Status](https://img.shields.io/badge/status-v0.x%20pre--release-orange)

A provider-agnostic, agent-flexible Docker container harness for LLM-assisted development and automation.

Each invocation is one self-contained unit — **agent + provider + mode → one container run → output / exit**. There is no internal orchestration; multi-step pipelines are built externally in shell, Makefiles, or CI.

```bash
./trigon-up.sh [PROJECT_PATH ...] [FLAGS]
```

---

## Why Trigon

Trigon aims to be a tool for flexible, safe, responsible, and effective AI
infrastructure and development, for individuals and organizations.

Trigon is an open-source Docker harness that launches AI coding agents — Claude Code,
OpenCode, and others, sandboxed in isolated containers, and pointed at any LLM backend, featuring custom toolsets and prompts.

When using Claude Code's CLI, Trigon takes advantage of Claude Code honouring the `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` environment variables. Point them at any Anthropic-compatible endpoint and the same agent talks to a different model — no code changes. Trigon builds on that one insight and generalises it along three independent axes:

| Axis | Flag | What it selects | Default |
|------|------|-----------------|---------|
| **Provider** | `--provider` | Which LLM backend answers requests | `anthropic` |
| **Agent** | `--agent` | Which coding agent runs in the container | `claude-code` |
| **Mode** | `--mode` | Which domain toolset is installed | `dev` |

These compose freely: any provider, with any agent, in any mode. Providers that don't speak the Anthropic format are handled transparently by a LiteLLM sidecar (see [Providers](#providers)).

---

## Prerequisites

- **Docker** with the **Compose v2** plugin (`docker compose`); `docker-compose` v1 also works
- **bash** 4+ recommended. The script avoids bash-4-only features, so macOS's stock bash 3.2 also works.
- **python3** on the host (used by the helper scripts in [`lib/`](lib/) for provider-YAML parsing and MCP config merging — standard library only, no `pip` packages needed)
- An account or API key for whichever provider you use (see [Authentication](#authentication))

**Platforms:**

- **Linux** — the reference platform, tested on Ubuntu.
- **macOS** — supported; BSD-userland portability fixes are applied (e.g. `mktemp`). Note: `--air-gap` and remote-Ollama networking rely on Linux Docker bridge behaviour and are untested on macOS.
- **Windows** — via **WSL2**, which is a real Linux environment and the closest to native; run Trigon from inside the WSL2 distro, not from native Windows.

---

## Quick start

```bash
# 1. Build the agent image once (Claude Code, dev mode)
./build.sh

# 2. Launch an interactive session against your project
./trigon-up.sh ~/my-project
```

On first launch with the default `anthropic` provider, Claude Code prompts you to log in (`/login`). That session is saved (see [Settings persistence](#settings-persistence)), so it's a one-time step per container name.

More examples:

```bash
# DeepSeek for cost-sensitive tasks (Anthropic-compatible, no proxy)
./trigon-up.sh ~/my-project --provider deepseek --api

# Local model, air-gapped (LiteLLM sidecar translates to Ollama)
./trigon-up.sh ~/my-project --provider ollama:qwen2.5 --air-gap

# Security audit (nmap, gobuster, nuclei, Go tools baked in)
./trigon-up.sh ~/my-project --mode security

# Non-interactive pipeline run
./trigon-up.sh ~/my-project --prompt-file scout.md --provider deepseek --api
```

Run `./trigon-up.sh --help` for the full flag reference.

---

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--provider NAME` | `anthropic` | Model provider. See [Providers](#providers) and [docs/providers.md](docs/providers.md) |
| `--agent NAME` | `claude-code` | Agent frontend (`claude-code`, `opencode`). See [Agents](#agents) |
| `--mode NAME` | `dev` | Domain toolset (`dev`, `security`). See [Modes](#modes) |
| `--name NAME` | `trigon-<agent>` | Container name; also keys the settings persistence directory |
| `--api` | off | Inject the provider's API key (`~/.anthropic_api_key` or `~/.{provider}_api_key`, or the env var named in the provider YAML) |
| `--yolo` | off | Skip agent permission prompts (`--dangerously-skip-permissions`; claude-code only) |
| `--root` | off | Run the container as root |
| `--playwright` | off | Playwright MCP via host Chrome on `localhost:9222` (host networking) |
| `--playwright-headless` | off | Playwright MCP with headless Chromium inside the container — no host Chrome, works with all providers |
| `--mcp NAME=URL` | — | Attach an external HTTP MCP server (repeatable). Merged into the project `.mcp.json` and restored on exit; a host-gateway route makes a server on the host reachable at `host.docker.internal`. Coexists with `--playwright`/`--playwright-headless`. See [docs/mcp.md](docs/mcp.md). |
| `--mcp-key VALUE` | — | Bearer token for `--mcp` servers, sent as `Authorization: Bearer VALUE`. Passed via env so the secret is never written into `.mcp.json`. |
| `--air-gap` | off | Block all outbound internet from the agent container. Requires a local provider (e.g. `--provider ollama:MODEL`); the LiteLLM sidecar retains host access for model calls. Incompatible with `--mcp` (host access is blocked). |
| `--prompt-file PATH` | — | Non-interactive: pass prompt content, run, and exit on completion |
| `--max-budget USD` | — | Cap API spend for pipeline runs (claude-code only) |
| `--security` | — | Alias for `--mode security` (backward compat) |
| `-h`, `--help` | — | Show usage and exit |

Multiple project directories can be passed as positional arguments (up to 5). The first mounts to `/app`, subsequent ones to `/app_2`…`/app_5`.

---

## Authentication

How the agent authenticates depends on the provider.

**Anthropic (default) — two options:**

- **Subscription (OAuth):** launch normally and run `/login` inside Claude Code. The OAuth token is stored in the settings directory and reused on every later run with the same `--name`.
- **API key:** pass `--api` to inject `ANTHROPIC_API_KEY` from your environment, or from `~/.anthropic_api_key` if the env var is unset. Billed per token.

**Third-party providers** always require an API key. Either export the provider's env var (e.g. `export DEEPSEEK_API_KEY=...`) or place it in `~/.{provider}_api_key` and pass `--api`. The exact env var name is declared in each `providers/*.yml`. Local providers (`ollama:*`) need no key.

> **Note:** don't mix an OAuth login and an injected API key in the same settings directory — Claude Code treats that as an auth conflict. Use a fresh `--name` to keep API-key runs separate from your logged-in session. `trigon-up.sh` warns when it detects this.

---

## Building images

```bash
./build.sh                                   # claude-code, dev mode (default)
./build.sh --mode security                   # claude-code, security mode
./build.sh --agent opencode                  # opencode, dev mode
```

Each `(agent, mode)` pair produces its own tagged image, e.g. `claude-code-dev:latest`, `claude-code-security:latest`.

The Claude Code CLI version defaults to npm `latest`. Pin a specific version if `latest` introduces a regression mid-project:

```bash
./build.sh --claude-version 2.1.144
./build.sh --agent opencode --opencode-version 0.x.y
```

---

## Providers

Trigon resolves providers in two tiers.

**Tier 1 — direct (no proxy, zero overhead).** Providers that speak the Anthropic Messages API natively. `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` are set; no extra containers.

| Provider | Example |
|----------|---------|
| `anthropic` | default |
| `deepseek` | `--provider deepseek` |
| `openrouter/MODEL` | `--provider openrouter/anthropic/claude-sonnet-4-5` |

**Tier 2 — LiteLLM sidecar.** Providers that need format translation. A LiteLLM container starts alongside the agent and exposes an Anthropic-compatible endpoint; the agent sees no difference.

| Provider | Example |
|----------|---------|
| `ollama:MODEL` | `--provider ollama:qwen2.5` |
| `openai/MODEL` | `--provider openai/gpt-4o` |
| `bedrock/MODEL` | `--provider bedrock/anthropic.claude-3-5-sonnet` |
| `litellm:CONFIG` | `--provider litellm:./my-config.yaml` (escape hatch) |

Provider config lives in `providers/*.yml`. For the full per-provider reference, model aliases (`fast`/`smart`/`reason`), privacy notes, **running Ollama on a remote machine over an SSH tunnel**, and how to add a provider, see **[docs/providers.md](docs/providers.md)** and the [schema spec](providers/schema.md).

---

## Agents

The `--agent` flag selects the coding agent that runs in the container. The provider is separate — it's the LLM the agent queries.

- **`claude-code`** (default) — Anthropic's Claude Code CLI. Mature tool-use loop, `CLAUDE.md` project context, MCP support, session persistence. Works with every provider tier.
- **`opencode`** — the open-source [OpenCode](https://opencode.ai) agent, with native multi-provider support. **Current limitations in Trigon:** dev mode only (no `--mode security`); `--yolo` and `--max-budget` have no effect (no equivalent flags).

Both agents support non-interactive `--prompt-file` pipeline mode. See **[docs/agents.md](docs/agents.md)** for the full comparison and how to add an agent.

---

## Modes

| Mode | Tools | Use case |
|------|-------|---------|
| `dev` | Python, Node, git, standard build tools | Software development |
| `security` | nmap, gobuster, nuclei, ffuf, Go tools | Pentesting, security audits |
| `data` *(planned — not yet implemented)* | pandas, numpy, LaTeX/xelatex, dbt | Data analysis, report generation |

See **[docs/modes.md](docs/modes.md)** for what each mode installs and how to add one.

---

## Settings persistence

Each named container (`--name`) gets its own settings directory on the host at `~/.trigon-settings-<name>`. It holds Claude Code's OAuth token, conversation history, and configuration, and persists across container runs — which is what makes login a one-time step per name.

---

## Project status

Trigon is **pre-release (v0.x)**. The core `claude-code + anthropic + dev/security` path is the stable reference; everything else layers on without breaking it.

| Milestone | Scope | Status |
|-----------|-------|--------|
| M0 | Repository bootstrap | ✅ Done |
| M1 | `--provider` switching (tier 1 + tier 2) | ✅ Done |
| M2 | Mode-aware build + `--playwright-headless` | ✅ Done |
| M3 | `--air-gap` network isolation | ✅ Done |
| M4 | Data mode (LaTeX) | ⏸ Deferred |
| M5 | OpenCode agent | ✅ Basic (further testing in progress) |
| M6 | Publication prep (docs, CI, benchmarks) | 🔲 In progress |
| M7 | Network audit log (`--audit`) | 🔲 Planned |

Full detail and gate conditions: [docs/v1_milestones_roadmap.md](docs/v1_milestones_roadmap.md).

---

## Directory structure

```
trigon/
├── trigon-up.sh             # main entrypoint
├── build.sh                 # build agent images
│
├── lib/                     # host-side helper scripts (python3, stdlib only)
│   ├── parse_provider.py    # provider YAML → shell vars
│   └── merge_mcp.py         # merge --mcp servers into .mcp.json
│
├── agents/
│   ├── claude-code/
│   │   ├── Dockerfile       # multi-stage: base → mode-{dev|security} → final
│   │   └── wrapper.sh       # mode-context-injecting entrypoint
│   └── opencode/
│       ├── Dockerfile
│       ├── wrapper.sh       # provider-config-generating entrypoint
│       └── provider-map.yml
│
├── modes/                   # per-mode package lists + context prompts
│   ├── dev/                 # packages.txt, requirements.txt
│   ├── security/            # + context.md (security tools prompt)
│   └── data/                # placeholder (planned)
│
├── providers/               # provider YAML configs
│   ├── schema.md
│   ├── anthropic.yml
│   ├── deepseek.yml
│   ├── openrouter.yml
│   ├── ollama.yml
│   ├── openai.yml
│   ├── bedrock.yml
│   └── custom-example.yml
│
├── compose/
│   ├── base.yml                  # shared service definition
│   ├── security.yml              # security mode fragment
│   ├── litellm.yml               # LiteLLM sidecar reference template
│   ├── mcp-config-template.json  # Playwright MCP (host Chrome)
│   └── mcp-config-headless.json  # Playwright MCP (in-container Chromium)
│   # litellm / playwright / air-gap fragments are generated at runtime
│
└── docs/
    ├── providers.md
    ├── agents.md
    ├── modes.md
    ├── mcp.md               # external --mcp HTTP servers
    ├── pipelines.md
    ├── trigon-architecture.md
    └── internal/            # planning & strategy docs (not user-facing)
```

---

## Origin

Trigon generalises [claude-in-container](https://github.com/Bergurth/claude-in-container) along three axes: provider, agent, and mode. The working `claude-code + anthropic + dev/security` implementation is the reference; the rest of the system layers on top without breaking it.

---

## License

Apache-2.0 — see [LICENSE](LICENSE).
