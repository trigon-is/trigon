# Trigon — Architecture Design

**Date:** 2026-06-02  
**Status:** Design exploration

---

## Core Model

Trigon is a **composable container harness** for LLM-assisted development and
automation. Each invocation is one self-contained unit:

```
agent + provider + mode + [prompt-file]  →  one container run  →  output / exit
```

There is no internal orchestration. Multi-step pipelines are built by chaining
container runs from outside the system — shell scripts, Makefiles, CI pipelines, etc.
The harness stays stateless and single-purpose per run.

```
┌─────────────────────────────────────────────────────┐
│  External Orchestrator (user's shell / CI / cron)   │
│                                                      │
│   trigon-up.sh --provider deepseek  \             │
│                   --prompt-file plan.md              │
│         ↓ output written to shared volume            │
│   trigon-up.sh --provider anthropic \             │
│                   --prompt-file implement.md         │
│         ↓ output written to shared volume            │
│   trigon-up.sh --provider ollama:qwen2.5 \        │
│                   --prompt-file review.md            │
└─────────────────────────────────────────────────────┘
```

Each container is ignorant of the others. Coordination is the caller's problem.

---

## Interface

```
./trigon-up.sh [PROJECT_PATH ...] [FLAGS]

Provider flags:
  --provider NAME         Select model provider (default: anthropic)
                          Forms: anthropic, deepseek, openrouter/model-slug,
                                 ollama:model-name, litellm:config-file

Agent flags:
  --agent NAME            Select agent frontend (default: claude-code)
                          Supported: claude-code, opencode

Mode flags:
  --mode NAME             Load domain-specific toolset (default: dev)
                          Supported: dev, security, (extensible)

Session flags:
  --name NAME             Container name (default: trigon-<agent>)
  --yolo                  Skip agent permission prompts
  --root                  Run container as root
  --playwright            Enable Playwright MCP browser automation

API / billing flags:
  --api                   Inject API key for the selected provider
  --max-budget USD        Cap spend for pipeline runs

Pipeline flags:
  --prompt-file PATH      Non-interactive run: pass prompt, exit on completion
```

---

## Provider Abstraction Layer

The central design problem is that different agents speak different API dialects.
Claude Code uses the Anthropic Messages API. OpenCode has its own config.

The solution is a two-tier provider resolution:

```
Provider name
     │
     ▼
┌──────────────────────────────────────────────┐
│  Resolution tier 1: native compatibility?    │
│                                              │
│  anthropic       → direct, no proxy          │
│  deepseek        → ANTHROPIC_BASE_URL        │
│  openrouter/*    → ANTHROPIC_BASE_URL        │
│  huggingface/*   → ANTHROPIC_BASE_URL        │
└──────────────────────┬───────────────────────┘
                       │ not natively compatible
                       ▼
┌──────────────────────────────────────────────┐
│  Resolution tier 2: LiteLLM sidecar          │
│                                              │
│  ollama:*        → LiteLLM sidecar → Ollama  │
│  openai/*        → LiteLLM sidecar → OpenAI  │
│  bedrock/*       → LiteLLM sidecar → Bedrock │
│  litellm:file    → LiteLLM sidecar (custom)  │
└──────────────────────────────────────────────┘
```

### Tier 1 — Environment variable injection

For Claude Code with Anthropic-compatible APIs:

```bash
ANTHROPIC_BASE_URL=https://api.deepseek.com/v1
ANTHROPIC_MODEL=deepseek-chat
```

No proxy container. No additional latency. Supported today by:
- DeepSeek (native `/v1/messages`)
- OpenRouter (`https://openrouter.ai/api/v1` with model slug)
- HuggingFace Inference API (some models)
- Any self-hosted Anthropic-compatible endpoint

### Tier 2 — LiteLLM sidecar

For providers that speak OpenAI format or require a translation layer:
- Ollama (local models: Qwen, Llama, Mistral, CodeLlama, etc.)
- OpenAI (GPT-4o, o3)
- AWS Bedrock
- Google Vertex AI
- Any custom LiteLLM config

LiteLLM exposes `/v1/messages` (Anthropic format) and translates to the target.
The agent container sets `ANTHROPIC_BASE_URL=http://litellm:4000`.

```yaml
# compose.yml (simplified)
services:
  agent:
    image: trigon-claude-code  # or trigon-opencode
    environment:
      - ANTHROPIC_BASE_URL=http://litellm:4000
      - ANTHROPIC_MODEL=${MODEL_NAME}
    depends_on:
      - litellm

  litellm:
    image: ghcr.io/berriai/litellm:main
    volumes:
      - ${LITELLM_CONFIG}:/app/config.yaml:ro
    command: --config /app/config.yaml
    profiles:
      - proxy   # only starts when needed
```

### Provider config files

Provider-specific settings live in `providers/`:

```
providers/
  anthropic.yml        → direct API, no proxy
  deepseek.yml         → ANTHROPIC_BASE_URL redirect
  openrouter.yml       → ANTHROPIC_BASE_URL redirect + model mappings
  ollama.yml           → LiteLLM sidecar + local Ollama socket
  bedrock.yml          → LiteLLM sidecar + AWS credentials
  custom-example.yml   → template for user-defined providers
```

Each file declares:
- `type`: direct | anthropic-compat | litellm-proxy
- `base_url`: override URL (for anthropic-compat)
- `model_map`: alias → provider model name (e.g. `smart: deepseek-reasoner`)
- `litellm_config`: path to LiteLLM YAML (for litellm-proxy type)
- `requires`: list of env vars that must be set (key names, not values)

---

## Agent Layer

The `--agent` flag selects the Docker image and entrypoint.

### claude-code (default)

- Image: `trigon-claude-code`
- Based on: `ubuntu:latest`
- Entrypoint: `claude` (or wrapper script for mode-specific context injection)
- Provider support: tier 1 (env vars) or tier 2 (LiteLLM sidecar)
- Inherited from `/app`: all security tools, Python stack, multi-project mounting

### opencode

- Image: `trigon-opencode`
- Based on: `ghcr.io/anomalyco/opencode` or custom build
- Entrypoint: `opencode`
- Provider support: OpenCode's native config system (separate from ANTHROPIC_BASE_URL)
- Volume: mount `opencode.config.json` with provider credentials

### Future agents

The agent abstraction makes it straightforward to add:
- `aider` — git-native coding agent
- `goose` — Block's open-source agent
- Custom agents (script-based, API-based)

Each agent needs: a Dockerfile, a compose service fragment, and a provider adapter
that maps Trigon's `--provider` to whatever config format the agent expects.

---

## Mode Layer (domain toolsets)

Modes inject domain-specific tools and system context into the container.
Implemented the same way as the existing `security-claude-wrapper.sh` pattern:
a wrapper script that prepends context before calling the agent.

```
modes/
  dev/
    Dockerfile.fragment     → apt packages, pip packages for dev
    context.md              → tool-awareness prompt injected at startup
  security/
    Dockerfile.fragment     → nmap, gobuster, nuclei, etc. (from existing)
    context.md              → security tools prompt (from existing)
  data/
    Dockerfile.fragment     → pandas, numpy, jupyter, dbt, etc.
    context.md              → data tooling context
```

Mode fragments are composited into the agent image at build time via multi-stage
builds or build args, not at runtime. This avoids large base images and keeps
each mode's image lean.

---

## Privacy / Air-Gap Mode

For the local-model-for-sensitive-code use case:

```bash
./trigon-up.sh ~/sensitive-project --provider ollama:qwen2.5 --air-gap
```

The `--air-gap` flag creates an `internal: true` Docker network. The agent
container is attached only to this network — no route to the internet. The
LiteLLM sidecar is attached to both the internal network and the default bridge,
so it can still reach Ollama on the host while the agent cannot reach anything
outside the compose project.

This satisfies the air-gap requirement: the model and the code never leave the machine.

---

## Directory Structure (proposed)

```
trigon/
│
├── trigon-up.sh              # main entrypoint script
├── build.sh                     # build all agent images
│
├── agents/
│   ├── claude-code/
│   │   ├── Dockerfile
│   │   └── wrapper.sh           # mode-aware entrypoint
│   └── opencode/
│       ├── Dockerfile
│       └── wrapper.sh
│
├── modes/
│   ├── dev/
│   │   ├── packages.txt         # apt packages
│   │   ├── requirements.txt     # pip packages
│   │   └── context.md           # injected at startup
│   ├── security/
│   │   └── ...                  # port from /app
│   └── data/
│       └── ...
│
├── providers/
│   ├── anthropic.yml
│   ├── deepseek.yml
│   ├── openrouter.yml
│   ├── ollama.yml
│   └── custom-example.yml
│
├── compose/
│   ├── base.yml                 # shared service definitions
│   ├── litellm.yml              # sidecar fragment (merged when needed)
│   ├── playwright.yml           # browser MCP fragment
│   └── (air-gap fragment generated at runtime by trigon-up.sh)
│
└── docs/
    ├── README.md
    ├── providers.md
    ├── agents.md
    ├── modes.md
    └── pipelines.md             # guide for external orchestration
```

Compose files are assembled at runtime using `docker compose -f base.yml -f litellm.yml ...`
fragment merging, driven by `trigon-up.sh`.

---

## Relationship to /app

Trigon is not a fork of `/app` — it's a generalisation. The existing system becomes
the `claude-code` agent with `dev` and `security` modes as the reference implementation.

Migration path:
1. Port `claude-up.sh` logic → `trigon-up.sh` (add `--provider`, `--agent`, `--mode`)
2. Port `Dockerfile` → `agents/claude-code/Dockerfile`
3. Port `Dockerfile.security` tool set → `modes/security/`
4. Port `security-claude-wrapper.sh` pattern → `agents/claude-code/wrapper.sh` (mode-aware)
5. Port `compose.yml` / `compose.security.yml` → `compose/base.yml` + mode fragments
6. Add `providers/` directory with the described YAML specs
7. Add LiteLLM sidecar fragment for tier-2 providers

The result: everything from `/app` still works, with new provider and agent flexibility
layered on top.

---

## Open Implementation Questions

1. **Provider YAML schema** — define the exact spec for `providers/*.yml` before
   writing `trigon-up.sh`. This is the API surface for extensibility.

2. **Agent provider adapter** — OpenCode does not use `ANTHROPIC_BASE_URL`. How does
   the `--provider` flag map to OpenCode's config? Options:
   - Generate an `opencode.config.json` at runtime from the provider spec
   - Maintain separate provider YAMLs per agent
   - Use OpenCode's built-in provider selection and expose it through Trigon flags

3. **Build strategy** — one fat image per agent+mode combo, or a base agent image
   with mode packages installed separately? Fat images are simpler; separate layers
   are more flexible for CI caching.

4. **Settings persistence** — the current `~/.claude-settings-<name>` scheme works
   for Claude Code. What is the equivalent for OpenCode? Needs investigation.

5. **Publish target** — GitHub org name, license, initial release scope.
