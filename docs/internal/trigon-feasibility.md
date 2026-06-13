# Trigon — Feasibility & Architecture Exploration

**Date:** 2026-06-02  
**Context:** Exploring evolution of the `claude-in-container` harness (`/app`) into a
provider-agnostic, hybrid-LLM dev + pipeline system.

---

## What the Current System Is

The `/app` harness is a thin Docker orchestrator around **one hardwired thing**: the
`@anthropic-ai/claude-code` CLI. Its value is:

- Clean isolation (container per session)
- Multi-project volume mounting
- Mode switching (normal / security)
- OAuth vs API key injection
- Playwright MCP sidecar
- Pipeline mode (`--prompt-file`)

Everything is Anthropic-locked. The `Dockerfile` does `npm install -g @anthropic-ai/claude-code`
and the entrypoint is `claude`. The compose files know nothing about providers.

---

## The Key Insight (from the HN thread / DeepClaude project)

Claude Code CLI is built on the **Anthropic Python/Node SDK**. That SDK respects two
environment variables:

```
ANTHROPIC_BASE_URL   — redirect all API calls to a different host
ANTHROPIC_MODEL      — override the model name
```

This means **Claude Code CLI can already talk to any Anthropic-API-compatible endpoint**
without any code changes to the CLI itself. The harness only needs to inject env vars.

What has an Anthropic-compatible API?
- **DeepSeek** — native `/v1/messages` compatibility; $0.87/M output tokens
- **OpenRouter** — routes to 200+ models behind a single Anthropic-compatible endpoint;
  offers ZDR (zero data retention) for privacy
- **LiteLLM proxy** — exposes `/v1/messages` and routes to 100+ providers including
  Ollama, Bedrock, Azure, Gemini, Groq, Cerebras, local models
- Any other "Anthropic-compatible" wrapper (e.g. a local proxy in the compose network)

This is the **cheapest possible provider-agnostic path**: no new agent, no rewrite,
just env var injection + optional proxy sidecar.

---

## Architecture Options (Effort vs. Generality)

### Option A — Minimal: `--provider` flag (1–2 days)

Add a `--provider` argument to the launch script. For providers with native
Anthropic-compatible APIs, just inject env vars. For others, spin up a LiteLLM
sidecar container in the compose network.

```
./trigon-up.sh /my/project --provider claude          # current behavior
./trigon-up.sh /my/project --provider deepseek        # ANTHROPIC_BASE_URL → DeepSeek
./trigon-up.sh /my/project --provider openrouter/qwen # route via OpenRouter
./trigon-up.sh /my/project --provider ollama:qwen2.5  # route via local LiteLLM sidecar
```

**What changes**: `claude-up.sh` (rename to `trigon-up.sh`), compose files get an
optional `litellm` service, Dockerfile unchanged.

**What stays locked**: The agent is still Claude Code CLI. Its tool-use loop, TUI, and
interaction model are Anthropic's. Model behaviour will differ between providers but the
harness doesn't know or care.

**When this is enough**: Cost optimization, privacy (local models), DeepSeek experiments,
OpenRouter routing. If the goal is "run Claude Code but cheaper or on a different model,"
this is the answer.

---

### Option B — Medium: LiteLLM Sidecar as Permanent Infrastructure (3–5 days)

Make LiteLLM a first-class compose service, always running. The agent container talks to
`http://litellm:4000` instead of `api.anthropic.com`. Provider config lives in a
`litellm-config.yaml` that gets volume-mounted.

```
trigon/
  compose.yml              — agent service + litellm service
  litellm-config.yaml      — provider routing table (user edits this)
  trigon-up.sh          — picks agent profile + compose
  providers/
    claude.yaml
    deepseek.yaml
    ollama.yaml
    openrouter.yaml
```

This gives you:
- Model aliasing (`smart` → Claude Opus, `fast` → Haiku, `cheap` → DeepSeek)
- Spend tracking per session
- Fallback chains (if Anthropic is down, fall back to OpenRouter)
- Easy local model support (point Ollama at the sidecar)
- Caching layer (LiteLLM has semantic caching)

Still locked to Claude Code CLI as the agent frontend.

---

### Option C — Multi-Agent Compose Profiles (1–2 weeks)

Add a second agent type alongside Claude Code. The prime candidate is **OpenCode**
(169k stars, TypeScript, docker-pullable: `ghcr.io/anomalyco/opencode`). OpenCode
natively supports multiple providers via its own config system, has a praised TUI, and
can run containerized.

```
./trigon-up.sh --agent claude --provider anthropic   # current
./trigon-up.sh --agent claude --provider deepseek    # Option A
./trigon-up.sh --agent opencode --provider gemini    # new agent + different provider
```

Each agent has its own Dockerfile and compose service definition. The `trigon-up.sh`
script selects the profile. Shared: volume mounting logic, settings persistence,
Playwright MCP, pipeline mode.

**Warranted when**: You want to evaluate different agent TUIs/behaviors, or Claude Code's
interaction model isn't the right fit for certain workflows (e.g. OpenCode's plan/build
agent distinction might suit structured pipelines better).

---

### Option D — Fresh Start / True Provider-Agnostic Harness (weeks–months)

Design Trigon from scratch as a meta-harness:
- **Provider layer**: LiteLLM or a custom router; swap freely
- **Agent layer**: pluggable CLI adapters (Claude Code, OpenCode, Aider, custom agents)
- **Tool layer**: domain-specific MCP servers (security, Django, data science, etc.)
- **Pipeline layer**: DAG orchestration beyond simple `--prompt-file`

This is warranted if:
- The agent itself (not just the model) needs to change per task
- You want pipeline orchestration (agent A does planning → agent B does implementation →
  agent C reviews)
- You're building something meant for others to use, not just personal tooling

The cost: no stable foundation to build on, you're solving the same problems again
(volume mounting, settings persistence, auth, etc.) but generically.

---

## What "Hybrid LLM" Unlocks (the interesting part)

Beyond simple "use DeepSeek instead of Claude," hybrid means:

**1. Reasoning model + coding model split**
Use DeepSeek R1 or o3 for architecture planning (high reasoning, expensive), then
a fast cheap model for implementation. This is already happening manually in dev
workflows; a proper harness could make it automatic via `--prompt-file` pipeline stages.

**2. Local for sensitive, remote for general**
Ollama with Qwen or Llama for code that can't leave the machine (proprietary, regulated),
remote Claude/GPT for open-source work. LiteLLM routing can enforce this policy.

**3. Cost ladder**
A tiered routing policy: try `claude-haiku` first, escalate to `claude-sonnet` if
confidence is low, `claude-opus` only for architectural decisions. LiteLLM supports
fallback chains that implement this automatically.

**4. Benchmarked model selection**
The terminal-bench and LiveCodeBench leaderboards (mentioned in the HN thread) provide
task-specific rankings. Different models are better at different tasks. A smart harness
could route based on task type detected from the prompt.

---

## Honest Assessment

| Question | Answer |
|----------|--------|
| Small addition/refactor? | **Yes** — Option A is ~100 lines of bash + a compose service |
| Warrants a new system? | **Only if** you want multi-agent or serious pipeline orchestration |
| Fresh start? | **Not yet** — the existing harness is solid and under-leveraged |
| Different harness? | OpenCode is the most credible alternative foundation |

**Recommended path for Trigon v0:**
Start with Option B (LiteLLM sidecar as permanent infra + `--provider` flag). This
unlocks the provider-agnostic story with minimal disruption to the working system, and
the architecture naturally extends toward Options C and D when needed.

---

## Open Questions (for user)

1. **What does "hybrid" mean here?** Same session / different subtasks, or just
   per-session provider choice?
2. **How important is keeping the Claude Code TUI?** If you're open to OpenCode or
   Aider, the options expand.
3. **Local model use case**: Is this primarily for cost, or are there privacy/air-gap
   requirements?
4. **Pipeline sophistication**: Is `--prompt-file` enough, or do you need DAG-style
   multi-step pipelines where agents hand off to each other?
5. **Target users**: Is Trigon personal tooling, team tooling, or intended to be
   a publishable project others use?

---

## Key External Resources

| Resource | Relevance |
|----------|-----------|
| `ANTHROPIC_BASE_URL` env var | The unlock — routes Claude Code to any compatible endpoint |
| [LiteLLM](https://github.com/BerriAI/litellm) | Best proxy for Anthropic-compatible routing to 100+ providers |
| [OpenRouter](https://openrouter.ai) | Cloud multi-provider routing with ZDR; no self-hosting |
| [OpenCode](https://github.com/sst/opencode) | Strongest multi-provider agent alternative to Claude Code CLI |
| [Cline](https://github.com/cline/cline) | VS Code extension; shows how provider-agnostic design is done |
| [Unichat MCP Server](https://github.com/amidabuddha/unichat-mcp-server) | MCP approach: route from within Claude to other providers |
| HN thread #48002136 | Real-world experiences switching Claude Code to DeepSeek |
| Terminal-bench | Leaderboard for coding agent evaluation across providers |
