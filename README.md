# Triquetra

A provider-agnostic, agent-flexible Docker container harness for LLM-assisted development and automation.

```
./triquetra-up.sh [PROJECT_PATH ...] [FLAGS]
```

Each invocation is one self-contained unit: **agent + provider + mode → one container run → output / exit**.  
No internal orchestration. Multi-step pipelines are built externally in shell, Makefiles, or CI.

---

## Quick start

```bash
# Default: Claude Code, Anthropic, dev mode
./triquetra-up.sh ~/my-project

# DeepSeek for cost-sensitive tasks (uses ANTHROPIC_BASE_URL trick, no proxy)
./triquetra-up.sh ~/my-project --provider deepseek --api

# Local model, air-gapped (LiteLLM sidecar translates to Ollama)
./triquetra-up.sh ~/my-project --provider ollama:qwen2.5 --air-gap

# Security audit (nmap, gobuster, nuclei, Go tools baked in)
./triquetra-up.sh ~/my-project --mode security

# Non-interactive pipeline run
./triquetra-up.sh ~/my-project --prompt-file scout.md --provider deepseek --api
```

---

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--provider NAME` | `anthropic` | Model provider. See [Provider reference](docs/providers.md) |
| `--agent NAME` | `claude-code` | Agent frontend. See [Agent reference](docs/agents.md) |
| `--mode NAME` | `dev` | Domain toolset (`dev`, `security`, `data`). See [Modes](docs/modes.md) |
| `--name NAME` | `triquetra-<agent>` | Container name (also determines settings persistence directory) |
| `--api` | off | Inject API key for the selected provider (`~/.anthropic_api_key` or `api_key_env` from provider YAML) |
| `--yolo` | off | Skip agent permission prompts (`--dangerously-skip-permissions`) |
| `--root` | off | Run container as root |
| `--playwright` | off | Enable Playwright MCP browser automation (connects to host Chrome on port 9222) |
| `--air-gap` | off | Block all outbound internet from the agent container. Requires a local provider (e.g. `--provider ollama:MODEL`). LiteLLM sidecar retains host access for model calls. |
| `--prompt-file PATH` | — | Non-interactive: pass prompt content and exit on completion |
| `--max-budget USD` | — | Cap API spend for pipeline runs |

Multiple project directories can be passed as positional arguments (up to 5). First mounts to `/app`, subsequent to `/app_2`…`/app_5`.

---

## Building images

```bash
# Build dev image (default)
./build.sh

# Build security image
./build.sh --mode security

# Build both
./build.sh --mode dev && ./build.sh --mode security
```

The Claude Code CLI version is **pinned** in the build (default: `2.1.144`). To build with a different version:

```bash
# Pin to a specific version
./build.sh --claude-version 2.1.200

# Build with latest (unpinned — may introduce regressions)
./build.sh --claude-version latest
```

The pin exists because `latest` can introduce breaking changes mid-project. To advance the pin, build with the target version, test, then update the default in `build.sh` and `agents/claude-code/Dockerfile`.

---

## Provider switching

Triquetra resolves providers in two tiers:

**Tier 1 — direct (no proxy, zero overhead)**  
Providers that speak the Anthropic Messages API natively.  
Claude Code's `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` env vars are set; no extra containers.

| Provider | Example |
|----------|---------|
| `anthropic` | default |
| `deepseek` | `--provider deepseek` |
| `openrouter/MODEL` | `--provider openrouter/anthropic/claude-sonnet-4-5` |

**Tier 2 — LiteLLM sidecar**  
Providers that need format translation. A LiteLLM container starts alongside the agent.

| Provider | Example |
|----------|---------|
| `ollama:MODEL` | `--provider ollama:qwen2.5` |
| `openai/MODEL` | `--provider openai/gpt-4o` |
| `bedrock/MODEL` | `--provider bedrock/anthropic.claude-3-5-sonnet` |

Provider config lives in `providers/*.yml`. See [Provider schema](docs/providers.md) and [schema spec](providers/schema.md).

---

## Modes

| Mode | Tools | Use case |
|------|-------|---------|
| `dev` | Python, Node, git, standard build tools | Software development |
| `security` | nmap, gobuster, nuclei, ffuf, Go tools | Pentesting, security audits |
| `data` | pandas, numpy, LaTeX/xelatex, dbt | Data analysis, report generation |

---

## Directory structure

```
triquetra/
├── triquetra-up.sh          # main entrypoint
├── build.sh                 # build agent images
│
├── agents/
│   └── claude-code/
│       ├── Dockerfile       # dev mode image
│       ├── Dockerfile.security
│       └── wrapper.sh       # mode-aware entrypoint
│
├── modes/
│   ├── dev/                 # dev toolset (packages, context)
│   ├── security/
│   │   └── context.md       # security tools context prompt
│   └── data/
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
│   ├── base.yml             # shared service definition
│   ├── litellm.yml          # LiteLLM sidecar fragment (tier-2 providers)
│   ├── playwright.yml       # browser MCP fragment
│   └── air-gap.yml          # air-gap network fragment (generated at runtime)
│
└── docs/
    ├── providers.md
    ├── agents.md
    ├── modes.md
    ├── pipelines.md
    └── triquetra-architecture.md
```

---

## Settings persistence

Each named container (`--name`) gets its own settings directory on the host at `~/.triquetra-settings-<name>`. This holds Claude Code's OAuth token, conversation history, and configuration — it persists across container restarts.

---

## Origin

Triquetra generalises [claude-in-container](https://github.com/Bergurth/claude-in-container) along three axes: provider, agent, and mode. The working `claude-code + anthropic + dev/security` implementation is the reference; the rest of the system layers on top without breaking it.

---

## License

MIT
