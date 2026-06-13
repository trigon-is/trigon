# Trigon — Session Start Primer

Use this file at the beginning of a new session to restore full context quickly.

---

## What Trigon is

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

## Current state (as of 2026-06-13)

### Recent changes (2026-06-13)

- **Project renamed Triquetra → Trigon** (complete). Entrypoint is now `trigon-up.sh`
  (the transitional `triquetra-up.sh` symlink was removed 2026-06-13). Renamed across the board:
  compose service `trigon`, env vars `TRIGON_MODE` / `TRIGON_IMAGE` / `TRIGON_PROVIDER_*`,
  settings dir `~/.trigon-settings-<name>`, wrapper binary `trigon-wrapper`, and the four
  triquetra-named doc files. **Images must be rebuilt** to bake in `TRIGON_MODE`.
- **Claude Code version un-pegged** in `build.sh` / `agents/claude-code/Dockerfile`:
  defaults to npm `latest`; pin with `build.sh --claude-version X.Y.Z`.
- **AI-DLC workflow rules vendored** under `docs/aidlc/` (from `awslabs/aidlc-workflows`)
  as reference for larger features; `docs/aidlc/aws-aidlc-rules/core-workflow.md` is the entrypoint.
- **M6 pass 1 (pre-push hygiene) done 2026-06-13:** `LICENSE` added (Apache-2.0 — decided,
  README updated from MIT), `.gitignore` added, README accuracy pass (un-pegged version text,
  dir structure, `--playwright-headless` in flags table), planning docs moved to `docs/internal/`,
  `trigon-up.sh` gained `--help`/usage, Playwright `.mcp.json` now restored/removed on exit,
  VPN leftover removed from `agents/claude-code/wrapper.sh`. Remote target: `github.com/trigon-is/trigon`.

### M0 — DONE (committed)

Repo bootstrapped at `/home/bergurth/projects/Trigon` (mount point inside the
container varies per session — check the volume list).
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
- `agents/claude-code/wrapper.sh` generalised — injects `modes/{TRIGON_MODE}/context.md` into `/settings/.claude/CLAUDE.md` at container start (Claude Code reads this automatically as user-level CLAUDE.md); replaces hardcoded security-mode detection
- `modes/security/context.md` cleaned up — now contains only the raw prompt text for injection
- `TRIGON_IMAGE` set to `{agent}-{mode}:latest` in `trigon-up.sh`; `compose/security.yml` image override removed
- `--playwright-headless` implemented: writes `mcp-config-headless.json` (headless flag, internal Chromium), generates compose fragment with `ipc: host` + `SYS_PTRACE`; restricted to dev mode; incompatible with `--playwright`
- Playwright (headless) is installed in the dev image via `playwright install --with-deps chromium`; browsers at `/usr/local/playwright-browsers`

**Gate:** `./build.sh --mode dev` and `./build.sh --mode security` produce correctly-tagged images; both launch; `--playwright-headless` works with `--provider deepseek:smart`

### M1 — DONE (committed, pre-testing)

`trigon-up.sh` with `--provider` flag fully implemented.

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
- `--air-gap` implemented (M3): `internal: true` Docker network isolates agent; LiteLLM retains host access; Claude Code itself requires `api.anthropic.com` for auth so full air-gap breaks it — true offline use requires OpenCode (M5)
- Settings dir renamed: `~/.trigon-settings-<name>` (was `~/.claude-settings-<name>`)
- `COMPOSE_CMD` is now a bash array — no more word-split issue with `docker compose`

**New/updated compose files:**
- `compose/base.yml`: service renamed `trigon`; image `${TRIGON_IMAGE:-claude-code-env}`;
  `network_mode: bridge` removed (default compose network handles NAT + inter-container DNS)
- `compose/security.yml`: security mode fragment (image override, GOPATH/PATH, results/wordlists
  volumes, NET_RAW + NET_ADMIN caps)
- `compose/litellm.yml`: reference template (script generates equivalent at runtime)

**Gate status:** M1 implementation complete. **Not yet tested end-to-end.**
Next action: run `./trigon-up.sh ~/project --provider deepseek --api --prompt-file scout.md`
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

6. **Single repo** — `/home/bergurth/projects/Trigon` is the Trigon repo.
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
    runs multiple agents in Docker with zero config. Trigon's differentiation:
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
| M1 | `trigon-up.sh` with `--provider` | ✅ Done (tested 2026-06-06) |
| M2 | Mode-aware build + `--playwright-headless` | ✅ Done (pre-testing) |
| M3 | `--air-gap` network isolation | ✅ Done (Claude Code limitation noted) |
| M4 | Data mode (LaTeX) | ⏸ Deferred |
| M5 | OpenCode agent | ✅ Done (basic launch confirmed 2026-06-10, further testing indicated) |
| M6 | Publication prep | 🔲 Planned |
| M7 | Network audit log (`--audit`) | 🔲 Planned |

---

### M5 — OpenCode agent (implementation notes, 2026-06-10)

All code implemented; gate test (`--agent opencode --prompt-file` exits cleanly)
in progress. Key decisions made:

- **Install method:** official install script (`curl https://opencode.ai/install | bash`)
  installs to `/root/.opencode/bin/`; binary copied to `/usr/local/bin/opencode`
  at build time (symlink fails — `/root/` is `700`, non-root runtime user can't traverse)
- **Settings persistence:** base.yml already sets `XDG_CONFIG_HOME=/settings/config`
  and `XDG_DATA_HOME=/settings/data`; OpenCode uses these automatically — no extra
  volume mounts needed
- **Provider config:** `agents/opencode/wrapper.sh` reads `TRIGON_PROVIDER_TYPE`
  (injected by `trigon-up.sh`) and generates `$XDG_CONFIG_HOME/opencode/config.json`
  at container startup for non-direct providers; pure Anthropic needs no config file
- **Pipeline mode:** wrapper handles via `PROMPT_FILE` env var →
  `opencode --no-tui --message "$(cat $PROMPT_FILE)"`; CMD is never overridden
- **`TRIGON_PROVIDER_TYPE` / `TRIGON_PROVIDER_MODEL`:** now injected for all agents,
  not just opencode

**Files added:**
- `agents/opencode/Dockerfile`
- `agents/opencode/wrapper.sh`
- `agents/opencode/provider-map.yml`

**Files changed:**
- `build.sh` — opencode valid agent; `--opencode-version` flag
- `trigon-up.sh` — agent validation unblocked; TRIGON_* env injection;
  auth guard scoped to claude-code; launch block branches on agent

---

## Open questions (still unresolved)

- **M5 further testing** — basic launch confirmed; pipeline mode (`--prompt-file`),
  litellm-proxy providers, and `--air-gap` not yet tested end-to-end
- **M1 gate test** — `--provider deepseek` not yet run against a real JSP scout prompt
- **Build strategy** — one fat image per agent+mode vs. layered base images
  (current plan: one image per combination; revisit if CI caching becomes painful)
- **GitHub remote** — pre-push hygiene done (M6 pass 1); push to
  `github.com/trigon-is/trigon` pending (run `gh repo create` on the host)

---

## How to orient a new session

Read this file, then check git log to see what's landed since this was written:
```bash
git -C /home/bergurth/projects/Trigon log --oneline
```

Key files to read depending on the task:
- `trigon-up.sh` — the main script (M1 implemented here)
- `providers/schema.md` — provider YAML spec
- `compose/base.yml`, `compose/security.yml`, `compose/litellm.yml` — compose fragments
- `docs/trigon-architecture.md` — internal design

---

## Quick reference: file map

```
/home/bergurth/projects/Trigon/       (mount point varies per session)
  trigon-up.sh                        main entrypoint
  build.sh                            builds {agent}-{mode}:latest images
  README.md                           project overview + quick-start
  LICENSE                             Apache-2.0
  .gitignore                          runtime artifacts (.mcp.json, security-results/ ...)

  agents/claude-code/
    Dockerfile                        multi-stage: base → mode-{dev|security} → final
    wrapper.sh                        mode context injection into ~/.claude/CLAUDE.md
  agents/opencode/
    Dockerfile / wrapper.sh           M5 — provider config generated at startup
    provider-map.yml

  modes/
    dev/packages.txt + requirements.txt
    security/context.md + packages.txt + requirements.txt
    data/.gitkeep                     placeholder (M4, deferred)

  compose/
    base.yml                          base service definition (service: trigon)
    security.yml                      security mode fragment
    litellm.yml                       litellm sidecar reference template
    mcp-config-template.json          Playwright MCP (host Chrome)
    mcp-config-headless.json          Playwright MCP (in-container Chromium)

  providers/
    schema.md                         canonical field reference
    anthropic.yml                     direct (no redirect)
    deepseek.yml                      anthropic-compat (tier 1)
    openrouter.yml                    anthropic-compat (tier 1)
    ollama.yml                        litellm-proxy (tier 2, local)
    openai.yml / bedrock.yml          litellm-proxy (tier 2)
    spark-qwen3.yml / spark-foundationsec.yml   remote Ollama via SSH tunnel
    custom-example.yml                template for user-defined providers

  docs/
    session-start.md                  this file
    v1_milestones_roadmap.md          milestone detail + gates
    trigon-architecture.md            internal design
    providers.md / agents.md / modes.md / pipelines.md
    aidlc/                            vendored AI-DLC workflow rules
    internal/                         planning & strategy docs (not user-facing)
```
