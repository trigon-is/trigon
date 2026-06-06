# Triquetra v0.1 — Milestones Roadmap

Last updated: 2026-06-06

---

## Status overview

| Milestone | Title | Status | Est. effort |
|-----------|-------|--------|-------------|
| M0 | Repository bootstrap | ✅ Done | — |
| M1 | `triquetra-up.sh` with `--provider` | ✅ Done (tested 2026-06-06) | — |
| M2 | Mode-aware build + `--playwright-headless` | ✅ Done (pre-testing) | — |
| M3 | `--no-internet` air-gap | 🔲 Planned | ½–1 day |
| M4 | Data mode (LaTeX) | 🔲 Planned | 1–2 days |
| M5 | OpenCode agent | 🔲 Planned | 1 day spike + 2–3 days |
| M6 | Publication prep | 🔲 Planned | 1–2 days |

---

## M0 — Repository bootstrap ✅ Done

Repo created at `/home/bergurth/projects/Triquetra` (= `/app_4` inside container).

**Delivered:**
- Skeleton directories: `agents/claude-code/`, `modes/{dev,security,data}/`, `compose/`, `providers/`
- Design docs moved to `docs/`
- Reference implementation files copied from `/app`
- Root `README.md` written

**Gate:** repo structured and committed ✓

**Notes:**
- GitHub remote not yet set up (deferred to M6)

---

## M1 — `triquetra-up.sh` with `--provider` ✅ Done

Core provider-switching mechanism. Tested 2026-06-06 with DeepSeek.

**Delivered:**
- `--provider` flag with tier-1 (anthropic-compat) and tier-2 (litellm-proxy) providers
- Embedded Python3 YAML parser — no `yq` or PyYAML dependency
- LiteLLM sidecar compose fragment generated at runtime; cleaned up on exit
- Provider-aware `--api` flag; `requires[]` guard for missing env vars
- Model aliases (`fast`, `smart`, `reason`) resolved per provider
- `ANTHROPIC_MODEL` only injected when user explicitly specifies a model
- `--playwright` as dynamically generated compose fragment (`network_mode: host`)
- `--playwright-headless` flag stubbed with warning (implementation in M2)
- `--no-internet` flag stubbed with warning (implementation in M3)
- `--security` backward-compat alias for `--mode security`
- Settings dir renamed to `~/.triquetra-settings-<name>`
- `COMPOSE_CMD` as bash array (fixes word-split issue)

**Gate:** `--provider deepseek:smart` interactive session confirmed working ✓

**Bugs found and fixed during testing (2026-06-06):**

| Bug | Fix |
|-----|-----|
| DeepSeek API renamed models (`deepseek-chat` → `deepseek-v4-flash`, `deepseek-reasoner` → `deepseek-v4-pro`) | Updated `providers/deepseek.yml` model names |
| DeepSeek is OpenAI-format, not Anthropic-format — `ANTHROPIC_BASE_URL` trick doesn't work | Reclassified DeepSeek from `anthropic-compat` (tier-1) to `litellm-proxy` (tier-2) in `providers/deepseek.yml` |
| LiteLLM config `model_name` used full prefixed name (`deepseek/deepseek-v4-pro`) but Claude Code sends bare name (`deepseek-v4-pro`) → model lookup failure | Fixed `triquetra-up.sh`: `model_name` now uses `$PROVIDER_MODEL`, `litellm_params.model` uses `$FULL_MODEL` |
| Claude.ai session token in settings dir conflicts with injected `ANTHROPIC_API_KEY` | Workaround: use a fresh `--name` that has no prior session. Script warning to be added (open item) |

**Open items from M1:**
- Auth conflict guard: script should detect a pre-existing `.claude.json` session token when
  using API key mode and warn the user (currently requires manual workaround)
- JSP scout end-to-end `--prompt-file` run not yet tested

---

## M2 — Mode-aware build + `--playwright-headless` ✅ Done

**Goal:** decouple images from `/app`; make `build.sh` the authoritative way to produce
Triquetra images; implement headless Playwright that works with all providers.

**Delivered:**
- `build.sh --agent claude-code [--mode dev|security]` — produces `claude-code-dev:latest` / `claude-code-security:latest`
- Single `Dockerfile` with `ARG MODE` and multi-stage: `base → mode-dev|mode-security → final`; `Dockerfile.security` removed
- `modes/dev/packages.txt` + `requirements.txt` — dev mode package lists (postgresql-client, sqlite3, jq, Django stack)
- `modes/security/packages.txt` + `requirements.txt` — security mode package lists (nmap, gobuster, Go tools, etc.)
- `wrapper.sh` generalised: injects `modes/${TRIQUETRA_MODE}/context.md` into `/settings/.claude/CLAUDE.md` at startup
- `modes/security/context.md` cleaned to raw prompt text only
- `TRIQUETRA_IMAGE` set to `{agent}-{mode}:latest` in `triquetra-up.sh`; `compose/security.yml` image override removed
- `--playwright-headless` implemented: headless MCP config, compose fragment with `ipc: host` + `SYS_PTRACE`; dev-mode only; incompatible with `--playwright`
- Chromium installed at build time via `playwright install --with-deps chromium`; browsers at `/usr/local/playwright-browsers`

**Gate:** `./build.sh --mode dev` and `./build.sh --mode security` produce correctly-tagged images; both launch;
`--playwright-headless` works with `--provider deepseek:smart`

**Open items from M2:**
- Image builds not yet tested end-to-end (Playwright download is ~300–500MB; first build will be slow)
- `--playwright-headless` with non-root user may need `--root` flag if Chrome sandbox fails

---

## M3 — `--no-internet` air-gap 🔲 Planned

**Goal:** hard network isolation for local-model runs (privacy, offline, academic).

**Scope:**
- `compose/no-internet.yml` network isolation fragment (replaces current stub)
- LiteLLM sidecar must remain reachable at `http://litellm:4000` (internal compose network)
  while all outbound internet is blocked
- Validation method: `curl https://example.com` inside container must fail

**Gate:** `--provider ollama:qwen2.5 --no-internet` verified via failed `curl` inside container

---

## M4 — Data mode (LaTeX) 🔲 Planned

**Goal:** JSP letter-writing pipeline needs a LaTeX toolchain inside the container.

**Scope:**
- `modes/data/`: `texlive-full`, `xelatex`, `latexmk`, Python data stack
- `modes/data/context.md` — agent prompt for data/document tasks
- `compose/data.yml` fragment if any runtime config needed

**Gate:** agent compiles a `.tex` file to `.pdf` inside container; PDF appears in mounted volume

---

## M5 — OpenCode agent 🔲 Planned

Parallel spike — does not block M2–M4 critical path.

**Goal:** prove provider switching works with a second agent (OpenCode natively supports
75+ providers, making it the long-term answer for the "any provider" use case).

**Scope:**
- Spike: research OpenCode config format, pipeline/non-interactive mode, settings persistence
- `agents/opencode/Dockerfile`, `wrapper.sh`, `provider-map.yml`
- `--agent opencode` no longer errors out

**Gate:** `--agent opencode --prompt-file` exits cleanly with output

**Open questions:**
- How `--provider` maps to OpenCode's native provider config
- Equivalent of `~/.triquetra-settings-<name>` for OpenCode settings persistence

---

## M6 — Publication prep 🔲 Planned

After M1–M4 stable.

**Scope:**
- `README.md` roadmap section + polished quick-start
- `CONTRIBUTING.md`, `LICENSE` (MIT)
- GitHub remote: `gh repo create`
- GitHub Actions CI (build + smoke test)
- Tag `v0.1.0`
