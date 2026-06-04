# Triquetra — Session Start Primer

Use this file at the beginning of a new session to restore full context quickly.

---

## What Triquetra is

A provider-agnostic, agent-flexible Docker container harness for LLM-assisted
development and automation. It generalises the existing `claude-in-container`
system (`/app`) along three axes:

| Axis | Flag | Default | Options (designed) |
|------|------|---------|-------------------|
| Provider | `--provider` | anthropic | deepseek, openrouter/MODEL, ollama:MODEL, openai/MODEL, bedrock/MODEL, litellm:FILE |
| Agent | `--agent` | claude-code | opencode |
| Mode | `--mode` | dev | security, data (planned) |

Each container run = one agent + one provider + one mode + optional prompt file.
**No internal orchestration.** Multi-step pipelines are external (shell, Makefile, CI).

---

## Key technical insight

Claude Code CLI respects `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` env vars.
Set them to any Anthropic-API-compatible endpoint and the CLI talks to that
provider instead. For non-compatible providers (Ollama, OpenAI format), a
LiteLLM sidecar container translates.

This means **provider switching requires zero changes to the agent** — only env
var injection in the launch script.

---

## Current state (as of 2026-06-02)

### What exists
- `/app` — working `claude-in-container` harness (claude-code, anthropic only)
  - `claude-up.sh` — main launch script
  - `Dockerfile` — dev mode image (Python/Django tools)
  - `Dockerfile.security` — security mode image (nmap, gobuster, nuclei, Go tools)
  - `compose.yml` / `compose.security.yml` — service definitions
  - `security-claude-wrapper.sh` — mode context injection pattern
  - Multi-project mounting, --playwright, --api, --prompt-file, --yolo all working

### What is designed but not yet implemented
- `/app_2/` — Triquetra design documents (this session's output)
  - `README.md` — project overview and quick start
  - `providers.md` — full provider reference
  - `agents.md` — agent comparison and adapter architecture
  - `modes.md` — mode system and build strategy
  - `pipelines.md` — external orchestration patterns
  - `triquetra-architecture.md` — internal design and component breakdown
  - `triquetra-feasibility.md` — original feasibility analysis with options A–D

### Active branches in `/app`
- `claude-code-sec` — security auditing features
- `django-claude` (later `master`) — general dev, original branch

---

## Design decisions made this session

1. **Per-session provider switching** (not within-session routing). Each container
   run specifies one provider. Hybrid pipelines = multiple container runs chained
   externally.

2. **Not married to Claude Code** — open to OpenCode or other agents. Claude Code
   is the default/reference implementation.

3. **Local model support is first-class** — all three motivations: cost, privacy
   (air-gap with `--no-internet`), and academic experimentation.

4. **Publishable project standard** — clean architecture, proper docs, extensible
   provider/agent/mode system. Not just personal hacks.

5. **LiteLLM sidecar** is the provider translation layer for non-Anthropic-compatible
   providers. It is optional (only starts when needed via compose profiles).

---

## What was NOT decided / open questions

- **Provider YAML schema** — needs to be finalised before implementing `triquetra-up.sh`
- **OpenCode provider adapter** — how `--provider` maps to OpenCode's native config
  (needs investigation of OpenCode config format)
- **Build strategy** — one fat image per agent+mode vs. layered base images
- **OpenCode settings persistence** — equivalent of `~/.claude-settings-<name>` unknown
- **Publish target** — GitHub org, license, initial release scope not decided

---

## Intended next session agenda

The user wants to explore **concrete use-cases** of Triquetra building blocks,
connecting two things:

1. **A pipeline implementation using `claude-in-container`** — likely a working
   `--prompt-file` pipeline the user has or is building. This will ground the
   discussion in something real.

2. **A strategic planning repo for an expansion** — a project the user is planning
   to grow; Triquetra's pipeline capabilities may be useful here.

The goal is to go from abstract architecture to concrete worked examples:
- What specific pipelines would look like (prompt files, stages, provider choices)
- How the three axes (provider/agent/mode) apply to real tasks
- Where the current `claude-in-container` is the bottleneck vs. where it's sufficient
- Potentially: start sketching `triquetra-up.sh` or a first working prototype

---

## How to orient a new session

Start the new session with:

> "I'm continuing work on Triquetra, a provider-agnostic container harness for
> LLM dev and automation. Design docs are in /app_2. The existing system is in
> /app (claude-in-container). Read /app_2/session-start.md for full context.
> Today I want to explore concrete use-cases connecting [pipeline project] and
> [strategic planning repo]."

Then point at:
- `/app_2/session-start.md` — this file
- `/app_2/triquetra-architecture.md` — for internal design questions
- `/app_2/pipelines.md` — for pipeline pattern reference
- `/app/claude-up.sh` — for the existing working implementation

---

## Quick reference: file map

```
/app/                          existing working system
  claude-up.sh                 launch script (Triquetra will generalise this)
  Dockerfile                   dev mode image
  Dockerfile.security          security mode image
  compose.yml                  normal compose
  compose.security.yml         security compose
  security-claude-wrapper.sh   mode context injection (pattern to port)

/app_2/                        Triquetra design docs (this session)
  README.md                    project overview
  providers.md                 provider reference
  agents.md                    agent reference
  modes.md                     mode/toolset reference
  pipelines.md                 orchestration patterns
  triquetra-architecture.md    internal design
  triquetra-feasibility.md     original feasibility analysis
  session-start.md             this file
```
