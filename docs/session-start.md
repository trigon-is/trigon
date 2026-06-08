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

### M0 — DONE (committed)

Repo bootstrapped at `/home/bergurth/projects/Triquetra` (= `/app_4` inside container).
- Skeleton directories created: `agents/claude-code/`, `modes/{dev,security,data}/`, `compose/`, `providers/`
- Design docs moved to `docs/`
- Reference implementation files copied from `/app` into correct locations
- Root `README.md` written (quick-start, flags table, provider tier table, dir structure)
- GitHub remote: **not yet set up** (skipped at M0, can be done any time with `gh repo create`)

### M2 — DONE (committed, pre-testing)

`build.sh` and unified Dockerfile with `ARG MODE` fully implemented.

**Key implementation details:**
- `build.sh --agent claude-code [--mode dev|security]` — produces `claude-code-dev:latest` / `claude-code-security:latest`
- Single `agents/claude-code/Dockerfile` with multi-stage: `base → mode-{dev|security} → final`; `Dockerfile.security` deleted
- `modes/dev/packages.txt` + `requirements.txt` — apt/pip package lists for dev mode
- `modes/security/packages.txt` + `requirements.txt` — apt/pip package lists for security mode
- `agents/claude-code/wrapper.sh` generalised — injects `modes/{TRIQUETRA_MODE}/context.md` into `/settings/.claude/CLAUDE.md` at container start (Claude Code reads this automatically as user-level CLAUDE.md); replaces hardcoded security-mode detection
- `modes/security/context.md` cleaned up — now contains only the raw prompt text for injection
- `TRIQUETRA_IMAGE` set to `{agent}-{mode}:latest` in `triquetra-up.sh`; `compose/security.yml` image override removed
- `--playwright-headless` implemented: writes `mcp-config-headless.json` (headless flag, internal Chromium), generates compose fragment with `ipc: host` + `SYS_PTRACE`; restricted to dev mode; incompatible with `--playwright`
- Playwright (headless) is installed in the dev image via `playwright install --with-deps chromium`; browsers at `/usr/local/playwright-browsers`

**Gate:** `./build.sh --mode dev` and `./build.sh --mode security` produce correctly-tagged images; both launch; `--playwright-headless` works with `--provider deepseek:smart`

### M1 — DONE (committed, pre-testing)

`triquetra-up.sh` with `--provider` flag fully implemented.

**Key implementation details:**
- `--provider` parsing handles all forms: `deepseek:smart`, `openrouter/org/model`,
  `ollama:qwen2.5:7b`, `litellm:/path/config.yaml`, bare `anthropic`
- Provider YAML loaded via **embedded Python3** — no yq, no PyYAML dep
- Tier-1 (`anthropic-compat`): injects `ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL` only; no extra container
- Tier-2 (`litellm-proxy`): generates litellm config YAML at runtime into temp file;
  generates a compose fragment dynamically (not a static file); cleans up on exit
- `requires[]` guard: fails immediately if a required env var is missing on the host
- `--api` flag is **provider-aware**: reads `api_key_env` from the YAML, tries env var
  then falls back to `~/.{provider}_api_key` file (e.g. `~/.deepseek_api_key`)
- `ANTHROPIC_MODEL` only injected when user explicitly specifies a model (avoids
  overriding Claude Code's default for `--provider anthropic`)
- Litellm-proxy gets a dummy `ANTHROPIC_API_KEY=sk-litellm-passthrough` so Claude
  Code's auth check passes against the local sidecar
- `--security` flag still works as a backward-compat alias for `--mode security`
- Playwright: now a dynamically generated compose fragment with `network_mode: host`
  (replaces the old sed hack on compose.yml); incompatible with litellm (detected + errored)
- `--playwright-headless` parsed but stubbed with warning (M2) — headless Chromium inside the
  container; no `network_mode: host` needed, compatible with all providers including tier-2
- `--air-gap` implemented (M3): internal Docker network isolates agent; LiteLLM retains host access
- Settings dir renamed: `~/.triquetra-settings-<name>` (was `~/.claude-settings-<name>`)
- `COMPOSE_CMD` is now a bash array — no more word-split issue with `docker compose`

**New/updated compose files:**
- `compose/base.yml`: service renamed `triquetra`; image `${TRIQUETRA_IMAGE:-claude-code-env}`;
  `network_mode: bridge` removed (default compose network handles NAT + inter-container DNS)
- `compose/security.yml`: security mode fragment (image override, GOPATH/PATH, results/wordlists
  volumes, NET_RAW + NET_ADMIN caps)
- `compose/litellm.yml`: reference template (script generates equivalent at runtime)

**Gate status:** M1 implementation complete. **Not yet tested end-to-end.**
Next action: run `./triquetra-up.sh ~/project --provider deepseek --api --prompt-file scout.md`
with `DEEPSEEK_API_KEY` set to verify the M1 gate.

### What still exists and works unchanged

- `/app` — the original working `claude-in-container` harness
  - Still fully functional; `claude-up.sh` continues to work as-is
  - Reference for Dockerfiles and compose patterns

---

## Design decisions made (all sessions to date)

1. **Per-session provider switching** (not within-session routing). Each container
   run specifies one provider. Hybrid pipelines = multiple container runs chained
   externally.

2. **Not married to Claude Code** — open to OpenCode or other agents. Claude Code
   is the default/reference implementation.

3. **Local model support is first-class** — cost, privacy (air-gap with `--air-gap`),
   and academic experimentation.

4. **Publishable project standard** — clean architecture, proper docs, extensible
   provider/agent/mode system.

5. **LiteLLM sidecar** is the provider translation layer for non-Anthropic-compatible
   providers. Optional (only starts when needed). Config is **generated at runtime**
   into a temp file — not maintained as a static YAML in the repo.

6. **Single repo** — `/home/bergurth/projects/Triquetra` is the Triquetra repo.
   The original plan to clone `/app` was superseded; the repo was started fresh
   (design docs existed first). `/app` git history lives at
   `github.com/Bergurth/claude-in-container` and can be referenced there.

7. **Target audience**: personal use + JSP V2/V3 production pipeline. Open-source
   publication is a goal but not a blocker on early milestones.

8. **OpenCode agent**: parallel spike (doesn't block M1–M4 critical path).

9. **Provider YAML schema**: fully resolved (see `providers/schema.md`).
   - Six core fields: `type`, `base_url`, `default_model`, `model_map`, `api_key_env`, `requires`
   - Two litellm-proxy fields: `litellm_model_prefix`, `litellm_api_base`
   - `--api` flag is provider-aware: reads `api_key_env` from the YAML
   - Parsing: `openrouter/`, `bedrock/`, `openai/` split on first `/`; all others split on first `:`

10. **VibePod awareness**: VibePod (open-source, March 2026) is the closest existing tool —
    runs multiple agents in Docker with zero config. Triquetra's differentiation:
    provider switching *within* Claude Code (the ANTHROPIC_BASE_URL trick), security
    mode as a domain toolset, and personal pipeline integration. OpenCode natively
    supports 75+ providers, making it the long-term answer for the "any provider" use
    case (which is why M5/OpenCode agent remains on the roadmap).

---

## Implementation milestones

Full detail, gate conditions, bugs found, and open items per milestone:
→ **[`docs/v1_milestones_roadmap.md`](v1_milestones_roadmap.md)**

Current status summary:

| Milestone | Title | Status |
|-----------|-------|--------|
| M0 | Repository bootstrap | ✅ Done |
| M1 | `triquetra-up.sh` with `--provider` | ✅ Done (tested 2026-06-06) |
| M2 | Mode-aware build + `--playwright-headless` | ✅ Done (pre-testing) |
| M3 | `--air-gap` air-gap | 🔲 Planned |
| M4 | Data mode (LaTeX) | 🔲 Planned |
| M5 | OpenCode agent | 🔲 Planned |
| M6 | Publication prep | 🔲 Planned |

---

## Open questions (still unresolved)

- **M1 gate test** — `--provider deepseek` not yet run against a real JSP scout prompt
- **OpenCode provider adapter** — how `--provider` maps to OpenCode's native config
  (needs investigation of OpenCode config format; M5 spike task)
- **Build strategy** — one fat image per agent+mode vs. layered base images
  (current plan: one image per combination; revisit if CI caching becomes painful)
- **OpenCode settings persistence** — equivalent of `~/.triquetra-settings-<name>` unknown
- **GitHub remote** — repo not yet pushed; `gh repo create` needed before M6

---

## How to orient a new session

Read this file, then check git log to see what's landed since this was written:
```bash
git -C /home/bergurth/projects/Triquetra log --oneline
```

Key files to read depending on the task:
- `triquetra-up.sh` — the main script (M1 implemented here)
- `providers/schema.md` — provider YAML spec
- `compose/base.yml`, `compose/security.yml`, `compose/litellm.yml` — compose fragments
- `docs/triquetra-architecture.md` — internal design

---

## Quick reference: file map

```
/home/bergurth/projects/Triquetra/     (= /app_4 inside the container)
  triquetra-up.sh                      main entrypoint — M1 IMPLEMENTED
  README.md                            project overview + quick-start

  agents/claude-code/
    Dockerfile                         dev image (from /app, M2 will refactor)
    Dockerfile.security                security image (from /app)
    wrapper.sh                         mode context injection (M2 will generalise)

  modes/
    dev/.gitkeep                       placeholder (M2)
    security/context.md               security tools prompt (from /app)
    data/.gitkeep                      placeholder (M4)

  compose/
    base.yml                           base service definition (service: triquetra)
    security.yml                       security mode fragment
    litellm.yml                        litellm sidecar reference template
    mcp-config-template.json           Playwright MCP config

  providers/
    schema.md                          canonical field reference
    anthropic.yml                      direct (no redirect)
    deepseek.yml                       anthropic-compat (tier 1) ← M1 primary target
    openrouter.yml                     anthropic-compat (tier 1)
    ollama.yml                         litellm-proxy (tier 2, local)
    openai.yml                         litellm-proxy (tier 2)
    bedrock.yml                        litellm-proxy (tier 2, AWS)
    custom-example.yml                 template for user-defined providers

  docs/
    session-start.md                   this file
    triquetra-architecture.md          internal design
    providers.md / agents.md / modes.md / pipelines.md
    triquetra-feasibility.md / v3_triquetra_use_case_analysis.md

/app/                                  original claude-in-container (still works)
  claude-up.sh                         reference — Triquetra generalises this
  Dockerfile / Dockerfile.security     reference images
  compose.yml / compose.security.yml   reference compose files
```
