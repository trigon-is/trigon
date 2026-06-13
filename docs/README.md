# Trigon

A provider-agnostic, agent-flexible container harness for LLM-assisted development
and automation.

---

## What it is

Trigon wraps an AI coding agent in a Docker container and lets you swap the model
provider at launch time — no code changes, no re-configuration between runs. Each
invocation is a self-contained unit: one agent, one provider, one mode, one optional
prompt. Multi-step pipelines are built by chaining invocations from outside the system.

The name reflects the three-axis design: **provider × agent × mode**.

---

## Quick start

```bash
# Interactive session — Claude Code, Anthropic, dev tooling (default)
./trigon-up.sh ~/my-project

# Same project, different provider
./trigon-up.sh ~/my-project --provider deepseek

# Local model, no data leaves the machine
./trigon-up.sh ~/my-project --provider ollama:qwen2.5

# Non-interactive pipeline run
./trigon-up.sh ~/my-project --provider deepseek --prompt-file ./prompts/plan.md

# Security audit mode
./trigon-up.sh ~/my-project --mode security --provider anthropic

# Different agent frontend
./trigon-up.sh ~/my-project --agent opencode --provider openrouter/google/gemini-2.5-pro
```

---

## The three axes

| Axis | What it controls | Default |
|------|-----------------|---------|
| `--provider` | Which LLM backend answers requests | `anthropic` |
| `--agent` | Which coding agent runs in the container | `claude-code` |
| `--mode` | Which domain tools are available | `dev` |

These are independently composable. Any provider works with any agent (where
technically supported). Any mode works with any agent.

---

## Full usage

```
./trigon-up.sh [PROJECT_PATH ...] [FLAGS]

Project paths:
  One or more directories to mount. First → /app, subsequent → /app_2, /app_3 ...
  Defaults to current directory. Maximum 5.

Provider:
  --provider NAME         anthropic (default), deepseek, openrouter/MODEL,
                          ollama:MODEL, bedrock/MODEL, litellm:CONFIG_FILE

Agent:
  --agent NAME            claude-code (default), opencode

Mode:
  --mode NAME             dev (default), security

Session:
  --name NAME             Container name (default: trigon-<agent>)
  --yolo                  Skip agent permission prompts
  --root                  Run container as root

Network / browser:
  --playwright            Enable Playwright MCP browser automation
  --air-gap           Disable outbound network (local models only)

API / billing:
  --api                   Inject API key for selected provider
  --max-budget USD        Cap spend (pipeline runs only)

Pipeline:
  --prompt-file PATH      Non-interactive: run prompt, exit on completion
```

---

## How provider switching works

Claude Code CLI respects two environment variables:

```
ANTHROPIC_BASE_URL   redirect API calls to a different host
ANTHROPIC_MODEL      override the model name
```

For providers that expose an Anthropic-compatible `/v1/messages` endpoint (DeepSeek,
OpenRouter, etc.), Trigon injects these variables — no proxy required.

For providers that do not (Ollama, OpenAI, Bedrock), Trigon spins up a LiteLLM
sidecar container in the same compose network. LiteLLM exposes an Anthropic-compatible
endpoint and translates requests to the target provider. The agent container sees no
difference.

See [providers.md](providers.md) for the full provider reference.

---

## Pipelines

Trigon does not orchestrate multi-step pipelines internally. Instead, each run is
a composable unit that you chain from outside:

```bash
#!/usr/bin/env bash
# example: plan with reasoning model → implement with fast model → review locally

./trigon-up.sh ~/project --provider deepseek:deepseek-reasoner \
  --prompt-file prompts/01-plan.md

./trigon-up.sh ~/project --provider anthropic \
  --prompt-file prompts/02-implement.md

./trigon-up.sh ~/project --provider ollama:qwen2.5 \
  --air-gap --prompt-file prompts/03-review.md
```

See [pipelines.md](pipelines.md) for patterns, examples, and CI integration.

---

## Relationship to claude-in-container

Trigon is a generalisation of the `claude-in-container` project (`/app`). The
existing dev and security modes map directly to Trigon's `--mode dev` and
`--mode security`. If you currently use `claude-up.sh`, `trigon-up.sh` is a
drop-in replacement for the default case.

---

## Documentation

- [providers.md](providers.md) — supported providers, configuration, adding new ones
- [agents.md](agents.md) — supported agents, differences, adding new ones
- [modes.md](modes.md) — domain toolsets, adding new modes
- [pipelines.md](pipelines.md) — external orchestration patterns and examples
- [trigon-architecture.md](trigon-architecture.md) — design rationale and internals
- [internal/](internal/) — planning and strategy docs (feasibility analysis, use-case studies)
