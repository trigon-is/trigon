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

## Current state (as of 2026-06-04)

### What exists and works

- `/app` — working `claude-in-container` harness (claude-code, anthropic only)
  - `claude-up.sh` — main launch script (Triquetra will generalise this)
  - `Dockerfile` — dev mode image (Python/Django tools)
  - `Dockerfile.security` — security mode image (nmap, gobuster, nuclei, Go tools)
  - `compose.yml` / `compose.security.yml` — service definitions
  - `security-claude-wrapper.sh` — mode context injection pattern
  - Multi-project mounting, --playwright, --api, --prompt-file, --yolo all working

### What is designed and ready for implementation

- `/app_4/` — Triquetra design documents + resolved schema
  - `README.md` — project overview and quick start
  - `providers.md` — full provider reference
  - `agents.md` — agent comparison and adapter architecture
  - `modes.md` — mode system and build strategy
  - `pipelines.md` — external orchestration patterns
  - `triquetra-architecture.md` — internal design and component breakdown
  - `triquetra-feasibility.md` — original feasibility analysis with options A–D
  - `v3_triquetra_use_case_analysis.md` — JSP V2/V3 use-case analysis
  - `providers/` — **provider YAML files, fully written and schema resolved**
    - `schema.md` — canonical field reference + parsing algorithm
    - `anthropic.yml`, `deepseek.yml`, `openrouter.yml`, `ollama.yml`, `openai.yml`, `bedrock.yml`
    - `custom-example.yml` — template for user-defined providers

---

## Design decisions made (all sessions to date)

1. **Per-session provider switching** (not within-session routing). Each container
   run specifies one provider. Hybrid pipelines = multiple container runs chained
   externally.

2. **Not married to Claude Code** — open to OpenCode or other agents. Claude Code
   is the default/reference implementation.

3. **Local model support is first-class** — cost, privacy (air-gap with `--no-internet`),
   and academic experimentation.

4. **Publishable project standard** — clean architecture, proper docs, extensible
   provider/agent/mode system.

5. **LiteLLM sidecar** is the provider translation layer for non-Anthropic-compatible
   providers. Optional (only starts when needed). Config is **generated at runtime**
   into a temp file — not maintained as a static YAML in the repo.

6. **New standalone repo**, cloned from `/app` to preserve git history. History is
   publication-quality; the commit log tells the authentic origin story.

7. **Target audience**: personal use + JSP V2/V3 production pipeline. Open-source
   publication is a goal but not a blocker on early milestones.

8. **OpenCode agent**: parallel spike (doesn't block M1–M4 critical path).

9. **Provider YAML schema**: fully resolved (see `providers/schema.md`).
   - Six core fields: `type`, `base_url`, `default_model`, `model_map`, `api_key_env`, `requires`
   - Two litellm-proxy fields: `litellm_model_prefix`, `litellm_api_base`
   - `--api` flag is provider-aware: reads `api_key_env` from the YAML
   - Parsing: `openrouter/`, `bedrock/`, `openai/` split on first `/`; all others split on first `:`

---

## Implementation milestones

### M0 — Repository bootstrap (½ day) — **NEXT**
- `git clone /app triquetra/` (preserves history), set new remote
- Copy design docs from `/app_4` into `triquetra/docs/`
- Create skeleton directories: `agents/`, `modes/`, `providers/`, `compose/`
- Write initial README
- **Gate:** repo exists with a real GitHub remote

### M1 — `triquetra-up.sh` with `--provider` (2–3 days)
*Primary JSP cost-reduction unlock.*
- All existing `claude-up.sh` flags preserved
- Add `--provider` flag: tier-1 (anthropic, deepseek, openrouter) and tier-2 (ollama via LiteLLM)
- Read `providers/*.yml` using embedded Python3 (no yq/PyYAML dep)
- `compose/litellm.yml` sidecar fragment, merged when tier-2 selected
- Model aliases (`deepseek:smart` → `deepseek-reasoner`)
- **Gate:** JSP scout stage runs successfully with `--provider deepseek`

### M2 — Directory restructure + mode-aware build (2–3 days)
- `agents/claude-code/Dockerfile` (with `ARG MODE`)
- `agents/claude-code/wrapper.sh` (mode context injection → exec claude)
- `modes/dev/`, `modes/security/` (port from `/app`)
- `compose/base.yml`, `compose/playwright.yml`, `compose/no-internet.yml`
- `build.sh --agent claude-code [--mode dev|security]`
- **Gate:** `./build.sh` produces correctly-tagged images; both launch

### M3 — `--no-internet` air-gap flag (½–1 day)
- `compose/no-internet.yml` network isolation fragment
- LiteLLM sidecar reachable, no outbound internet
- **Gate:** `--provider ollama:qwen2.5 --no-internet` verified via failed `curl` inside container

### M4 — Data mode (1–2 days)
*JSP letter-writing needs LaTeX.*
- `modes/data/`: texlive-full, xelatex, latexmk + Python data stack
- **Gate:** agent compiles `.tex` to `.pdf` inside container, PDF appears in mounted volume

### M5 — OpenCode agent (spike 1 day → integration 2–3 days)
- Research: OpenCode config format, pipeline mode, settings persistence
- `agents/opencode/Dockerfile`, `wrapper.sh`, `provider-map.yml`
- **Gate:** `--agent opencode --prompt-file` exits cleanly with output

### M6 — Publication prep (1–2 days) — after M1–M4 stable
- README, CONTRIBUTING.md, LICENSE (MIT)
- GitHub Actions CI
- Tag `v0.1.0`

---

## Open questions (still unresolved)

- **OpenCode provider adapter** — how `--provider` maps to OpenCode's native config
  (needs investigation of OpenCode config format; M5 spike task)
- **Build strategy** — one fat image per agent+mode vs. layered base images
  (current plan: one image per combination; revisit if CI caching becomes painful)
- **OpenCode settings persistence** — equivalent of `~/.claude-settings-<name>` unknown
- **Publish target** — GitHub org name, license confirmed as MIT

---

## How to orient a new session

The next session should start with **M0**: setting up the repository.

Key files to read:
- `/app_4/session-start.md` — this file
- `/app_4/providers/schema.md` — provider YAML spec (fully resolved)
- `/app_4/triquetra-architecture.md` — internal design
- `/app/claude-up.sh` — the working script that `triquetra-up.sh` generalises

---

## Quick reference: file map

```
/app/                          existing working system (reference implementation)
  claude-up.sh                 launch script (Triquetra will generalise this)
  Dockerfile                   dev mode image
  Dockerfile.security          security mode image
  compose.yml                  normal compose
  compose.security.yml         security compose
  security-claude-wrapper.sh   mode context injection (pattern to port)

/app_4/                        Triquetra design docs + resolved schema
  README.md                    project overview
  providers.md                 provider reference
  agents.md                    agent reference
  modes.md                     mode/toolset reference
  pipelines.md                 orchestration patterns
  triquetra-architecture.md    internal design
  triquetra-feasibility.md     original feasibility analysis
  v3_triquetra_use_case_analysis.md  JSP V2/V3 use cases + K8s path
  providers/
    schema.md                  canonical provider YAML field reference
    anthropic.yml              direct provider (no redirect)
    deepseek.yml               anthropic-compat (tier 1)
    openrouter.yml             anthropic-compat (tier 1)
    ollama.yml                 litellm-proxy (tier 2, local)
    openai.yml                 litellm-proxy (tier 2)
    bedrock.yml                litellm-proxy (tier 2, AWS)
    custom-example.yml         template for new providers
  session-start.md             this file
```
