# Trigon v0.1 — Milestones Roadmap

Last updated: 2026-06-13

---

## Status overview

| Milestone | Title | Status | Est. effort |
|-----------|-------|--------|-------------|
| M0 | Repository bootstrap | ✅ Done | — |
| M1 | `trigon-up.sh` with `--provider` | ✅ Done (tested 2026-06-06) | — |
| M2 | Mode-aware build + `--playwright-headless` | ✅ Done (pre-testing) | — |
| M3 | `--air-gap` network isolation | ✅ Done (Claude Code limitation noted) | — |
| M4 | Data mode (LaTeX) | ⏸ Deferred | 1–2 days |
| M5 | OpenCode agent | ✅ Done (basic launch confirmed 2026-06-10) | 1 day spike + 2–3 days |
| M6 | Publication prep | 🔲 Planned | 3–4 days |
| M7 | Network audit log (`--audit`) | 🔲 Planned | 1–2 days |

---

## M0 — Repository bootstrap ✅ Done

Repo created at `/home/bergurth/projects/Trigon` (= `/app_4` inside container).

**Delivered:**
- Skeleton directories: `agents/claude-code/`, `modes/{dev,security,data}/`, `compose/`, `providers/`
- Design docs moved to `docs/`
- Reference implementation files copied from `/app`
- Root `README.md` written

**Gate:** repo structured and committed ✓

**Notes:**
- GitHub remote not yet set up (deferred to M6)

---

## M1 — `trigon-up.sh` with `--provider` ✅ Done

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
- `--air-gap` flag stubbed with warning (implemented in M3)
- `--security` backward-compat alias for `--mode security`
- Settings dir renamed to `~/.trigon-settings-<name>`
- `COMPOSE_CMD` as bash array (fixes word-split issue)

**Gate:** `--provider deepseek:smart` interactive session confirmed working ✓

**Bugs found and fixed during testing (2026-06-06):**

| Bug | Fix |
|-----|-----|
| DeepSeek API renamed models (`deepseek-chat` → `deepseek-v4-flash`, `deepseek-reasoner` → `deepseek-v4-pro`) | Updated `providers/deepseek.yml` model names |
| DeepSeek is OpenAI-format, not Anthropic-format — `ANTHROPIC_BASE_URL` trick doesn't work | Reclassified DeepSeek from `anthropic-compat` (tier-1) to `litellm-proxy` (tier-2) in `providers/deepseek.yml` |
| LiteLLM config `model_name` used full prefixed name (`deepseek/deepseek-v4-pro`) but Claude Code sends bare name (`deepseek-v4-pro`) → model lookup failure | Fixed `trigon-up.sh`: `model_name` now uses `$PROVIDER_MODEL`, `litellm_params.model` uses `$FULL_MODEL` |
| Claude.ai session token in settings dir conflicts with injected `ANTHROPIC_API_KEY` | Workaround: use a fresh `--name` that has no prior session. Script warning to be added (open item) |

**Open items from M1:**
- Auth conflict guard: script should detect a pre-existing `.claude.json` session token when
  using API key mode and warn the user (currently requires manual workaround)
- JSP scout end-to-end `--prompt-file` run not yet tested

---

## M2 — Mode-aware build + `--playwright-headless` ✅ Done

**Goal:** decouple images from `/app`; make `build.sh` the authoritative way to produce
Trigon images; implement headless Playwright that works with all providers.

**Delivered:**
- `build.sh --agent claude-code [--mode dev|security]` — produces `claude-code-dev:latest` / `claude-code-security:latest`
- Single `Dockerfile` with `ARG MODE` and multi-stage: `base → mode-dev|mode-security → final`; `Dockerfile.security` removed
- `modes/dev/packages.txt` + `requirements.txt` — dev mode package lists (postgresql-client, sqlite3, jq, Django stack)
- `modes/security/packages.txt` + `requirements.txt` — security mode package lists (nmap, gobuster, Go tools, etc.)
- `wrapper.sh` generalised: injects `modes/${TRIGON_MODE}/context.md` into `/settings/.claude/CLAUDE.md` at startup
- `modes/security/context.md` cleaned to raw prompt text only
- `TRIGON_IMAGE` set to `{agent}-{mode}:latest` in `trigon-up.sh`; `compose/security.yml` image override removed
- `--playwright-headless` implemented: headless MCP config, compose fragment with `ipc: host` + `SYS_PTRACE`; dev-mode only; incompatible with `--playwright`
- Chromium installed at build time via `playwright install --with-deps chromium`; browsers at `/usr/local/playwright-browsers`

**Gate:** `./build.sh --mode dev` and `./build.sh --mode security` produce correctly-tagged images; both launch;
`--playwright-headless` works with `--provider deepseek:smart`

**Open items from M2:**
- Image builds not yet tested end-to-end (Playwright download is ~300–500MB; first build will be slow)
- `--playwright-headless` with non-root user may need `--root` flag if Chrome sandbox fails

---

## M3 — `--air-gap` network isolation ✅ Done (with known limitation)

**Goal:** hard network isolation for local-model runs (privacy, offline, academic).

**Delivered:**
- Flag renamed `--no-internet` → `--air-gap` (cleaner intent; local LLM ≠ no internet)
- Runtime-generated compose fragment with `internal: true` Docker network
- Agent container: `air_gap` network only — no route to internet
- LiteLLM sidecar: `air_gap` + `default` — retains host access for Ollama (`host.docker.internal:11434`)
- `--air-gap` + tier-1 provider → error; `--air-gap` + `--playwright` → error; `--air-gap` + `--playwright-headless` → warn
- `drop_params: true` added to generated LiteLLM config (fixes Ollama `context_management` rejection)
- Auth conflict guard: warns when a pre-existing claude.ai OAuth session exists alongside API key injection

**Known limitation — Claude Code + air-gap:**
Claude Code makes hardcoded auth calls to `api.anthropic.com` on startup, independent of
`ANTHROPIC_BASE_URL`. With `--air-gap` active, these calls are blocked and Claude Code
cannot start. The network isolation primitive is correct, but **Claude Code is not compatible
with full air-gap operation**. Two usable modes remain:

| Mode | Works? | Notes |
|------|--------|-------|
| `--provider ollama:MODEL` (no `--air-gap`) | ✅ | Inference stays local; Claude Code auth touches claude.ai |
| `--provider ollama:MODEL --air-gap` | ❌ | Claude Code can't auth — needs OpenCode (M5) |

True zero-Anthropic-contact operation requires a different agent. OpenCode (M5) has no
hardcoded Anthropic dependency and is the correct long-term path for this use case.

**Gate:** `--provider ollama:qwen2.5-coder:7b` (without `--air-gap`) confirmed reachable via LiteLLM; `curl https://example.com` fails inside an air-gapped container

---

## M4 — Data mode (LaTeX) 🔲 Planned

**Goal:** JSP letter-writing pipeline needs a LaTeX toolchain inside the container.

**Scope:**
- `modes/data/`: `texlive-full`, `xelatex`, `latexmk`, Python data stack
- `modes/data/context.md` — agent prompt for data/document tasks
- `compose/data.yml` fragment if any runtime config needed

**Gate:** agent compiles a `.tex` file to `.pdf` inside container; PDF appears in mounted volume

---

## M5 — OpenCode agent ✅ Done (basic launch confirmed 2026-06-10)

**Goal:** prove provider switching works with a second agent.

**Delivered:**
- `agents/opencode/Dockerfile` — ubuntu:24.04 base; install script → binary copied to
  `/usr/local/bin/opencode` (symlink fails: `/root/` is 700, non-root runtime user
  can't traverse; copy is the fix)
- `agents/opencode/wrapper.sh` — generates `$XDG_CONFIG_HOME/opencode/config.json` at
  startup from `TRIGON_PROVIDER_TYPE`; pipeline mode via `PROMPT_FILE` env var →
  `opencode --no-tui --message`; CMD never overridden
- `agents/opencode/provider-map.yml` — documents provider type → OpenCode config mapping
- `build.sh` — `opencode` valid agent; `--opencode-version` flag
- `trigon-up.sh` — agent validation unblocked; `TRIGON_PROVIDER_TYPE` +
  `TRIGON_PROVIDER_MODEL` injected for all agents; auth guard scoped to claude-code;
  launch block branches on `$AGENT`
- Settings persistence: base.yml `XDG_CONFIG_HOME=/settings/config` and
  `XDG_DATA_HOME=/settings/data` already handled — no extra mounts needed

**Gate:** `--agent opencode --provider anthropic` launches and produces output ✓

**Further testing indicated (not yet run):**
- Pipeline mode: `--prompt-file` exits cleanly with output
- Tier-2 providers: `--provider ollama:MODEL` via litellm sidecar
- `--air-gap` with opencode + local model

---

## M6 — Publication prep 🔲 Planned

After M1–M4 stable.

**Scope:**
- ✅ Rename project Triquetra → Trigon throughout (scripts, docs, env vars, settings dir, wrapper binary, service name) — done 2026-06-12; requires image rebuild to pick up `TRIGON_MODE`
- `README.md` roadmap section + polished quick-start (public audience framing)
- `CONTRIBUTING.md`, `LICENSE` (Apache-2.0 — final licence decision to be confirmed at publication)
- GitHub remote: push to `github.com/trigon-is/trigon`
- GitHub Actions CI (build + smoke test)
- Tag `v0.1.0`
- **Benchmarks:**
  - `benchmarks/tasks/dev/` — 5 task prompt files + `verify-XX.sh` scripts (see `docs/benchmark-spec.md`)
  - `benchmarks/tasks/security/` — 5 task prompt files (human-scored for v1)
  - `benchmarks/run.sh` — runner: launches `trigon-up.sh` per task, calls verify script, writes results CSV
  - `benchmarks/results/README.md` — generated leaderboard summary table
  - Baseline run: all bundled providers, dev suite; results committed at launch

---

## M7 — Network audit log (`--audit`) 🔲 Planned

After M6. Post-publication feature targeting compliance and public sector use cases.

**Goal:** produce a structured, human-readable audit trail of all outbound network
requests made during a Trigon session — a compliance artifact, not just a developer
debugging tool.

**Scope:**
- `--audit` flag in `trigon-up.sh`
- Transparent proxy sidecar (mitmproxy or equivalent) as a generated compose fragment
- Log format: structured JSON or CSV — timestamp, destination host, method, request size
- Session-end summary report written to `audit-log/` in the mounted project directory
- `--air-gap --audit` combination: audit log proves zero outbound requests (strongest
  possible privacy guarantee for GDPR/public sector contexts)

**Differentiation from VibePod:** VibePod's proxy is framed as developer traffic
monitoring. Trigon's audit log is framed as a compliance artifact — output readable
by a data protection officer, not just a developer.

**Gate:** `--audit` run produces a session log and summary report; `--air-gap --audit`
run produces an empty log confirming zero outbound requests.

**Reference:** `docs/community-and-gtm-strategy.md` — proposed feature section
