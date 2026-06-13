# Trigon

A provider-agnostic, agent-flexible Docker container harness for LLM-assisted development and automation.

```
./trigon-up.sh [PROJECT_PATH ...] [FLAGS]
```

Each invocation is one self-contained unit: **agent + provider + mode → one container run → output / exit**.  
No internal orchestration. Multi-step pipelines are built externally in shell, Makefiles, or CI.

---

## Quick start

```bash
# One-time: build the agent image (see "Building images" below)
./build.sh

# Default: Claude Code, Anthropic, dev mode
./trigon-up.sh ~/my-project

# DeepSeek for cost-sensitive tasks (uses ANTHROPIC_BASE_URL trick, no proxy)
./trigon-up.sh ~/my-project --provider deepseek --api

# Local model, air-gapped (LiteLLM sidecar translates to Ollama)
./trigon-up.sh ~/my-project --provider ollama:qwen2.5 --air-gap

# Security audit (nmap, gobuster, nuclei, Go tools baked in)
./trigon-up.sh ~/my-project --mode security

# Non-interactive pipeline run
./trigon-up.sh ~/my-project --prompt-file scout.md --provider deepseek --api
```

---

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--provider NAME` | `anthropic` | Model provider. See [Provider reference](docs/providers.md) |
| `--agent NAME` | `claude-code` | Agent frontend. See [Agent reference](docs/agents.md) |
| `--mode NAME` | `dev` | Domain toolset (`dev`, `security`, `data`). See [Modes](docs/modes.md) |
| `--name NAME` | `trigon-<agent>` | Container name (also determines settings persistence directory) |
| `--api` | off | Inject API key for the selected provider (`~/.anthropic_api_key` or `api_key_env` from provider YAML) |
| `--yolo` | off | Skip agent permission prompts (`--dangerously-skip-permissions`) |
| `--root` | off | Run container as root |
| `--playwright` | off | Enable Playwright MCP browser automation (connects to host Chrome on port 9222; host networking) |
| `--playwright-headless` | off | Playwright MCP with headless Chromium inside the container — no host Chrome needed, works with all providers |
| `--air-gap` | off | Block all outbound internet from the agent container. Requires a local provider (e.g. `--provider ollama:MODEL`). LiteLLM sidecar retains host access for model calls. |
| `--prompt-file PATH` | — | Non-interactive: pass prompt content and exit on completion |
| `--max-budget USD` | — | Cap API spend for pipeline runs |
| `--security` | — | Alias for `--mode security` (backward compat) |
| `-h`, `--help` | — | Show usage and exit |

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

The Claude Code CLI version defaults to npm `latest`. Pin a specific version if `latest` introduces a regression mid-project:

```bash
./build.sh --claude-version 2.1.144
```

OpenCode images are built the same way (`./build.sh --agent opencode`, optionally `--opencode-version VERSION`).

---

## Provider switching

Trigon resolves providers in two tiers:

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

## Remote Ollama via SSH tunnel

If Ollama runs on a remote machine (e.g. a lab GPU server or an NVIDIA DGX Spark), you can reach it without any server-side changes using an SSH port forward.

**1. Open the tunnel on your host — keep this terminal open:**
```bash
# Bind to 0.0.0.0, not 127.0.0.1 — Docker containers reach the host via the bridge IP,
# not loopback, so loopback-only tunnels are invisible to containers.
ssh -N -L 0.0.0.0:11435:localhost:11434 user@remote-host
```

**2. Allow Docker containers to reach the tunnel port (one-time, Linux only):**
```bash
# Docker containers on compose networks arrive on br-XXXX interfaces, not docker0.
# Without this rule, the bridge traffic is dropped before reaching the tunnel.
sudo iptables -I INPUT -i br+ -p tcp --dport 11435 -j ACCEPT

# Make it permanent (Ubuntu/Debian):
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```

**3. Create a provider YAML** (see `providers/spark-qwen3.yml` as a reference):
```yaml
type: litellm-proxy
litellm_model_prefix: "ollama/"
litellm_api_base: "http://host.docker.internal:11435"
default_model: qwen3:32b
api_key_env: ""
requires: []
supports_thinking: false
notes: "Requires SSH tunnel: ssh -N -L 0.0.0.0:11435:localhost:11434 user@remote-host"
```

**4. Launch:**
```bash
./trigon-up.sh ~/my-project --provider my-remote-ollama --api
```

### Model selection for remote Ollama

Not all models work equally well through the LiteLLM→Ollama translation layer:

- **Prefer models with native thinking support** (`qwen3`, `deepseek-r1`): Claude Code always sends thinking parameters; models that don't understand them will error. Set `supports_thinking: false` in the provider YAML for models that lack it (e.g. older Llama, Mistral, most fine-tunes) — this tells LiteLLM to strip the parameter before forwarding.
- **`--prompt-file` mode is more reliable than interactive** for local models: bounded, single-shot tasks play to the model's strengths and avoid the multi-tool looping that interactive sessions depend on.
- **For agentic tool-use**, `qwen3:32b` and `qwen3-coder:30b` have the most stable tool-calling behaviour of currently available Ollama models.

---

## Modes

| Mode | Tools | Use case |
|------|-------|---------|
| `dev` | Python, Node, git, standard build tools | Software development |
| `security` | nmap, gobuster, nuclei, ffuf, Go tools | Pentesting, security audits |
| `data` *(planned — not yet implemented)* | pandas, numpy, LaTeX/xelatex, dbt | Data analysis, report generation |

---

## Directory structure

```
trigon/
├── trigon-up.sh             # main entrypoint
├── build.sh                 # build agent images
│
├── agents/
│   ├── claude-code/
│   │   ├── Dockerfile       # multi-stage: base → mode-{dev|security} → final
│   │   └── wrapper.sh       # mode-context-injecting entrypoint
│   └── opencode/
│       ├── Dockerfile
│       ├── wrapper.sh       # provider-config-generating entrypoint
│       └── provider-map.yml
│
├── modes/                   # per-mode package lists + context prompts
│   ├── dev/                 # packages.txt, requirements.txt
│   ├── security/            # + context.md (security tools prompt)
│   └── data/                # placeholder (planned)
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
│   ├── base.yml                  # shared service definition
│   ├── security.yml              # security mode fragment
│   ├── litellm.yml               # LiteLLM sidecar reference template
│   ├── mcp-config-template.json  # Playwright MCP (host Chrome)
│   └── mcp-config-headless.json  # Playwright MCP (in-container Chromium)
│   # litellm / playwright / air-gap fragments are generated at runtime
│
└── docs/
    ├── providers.md
    ├── agents.md
    ├── modes.md
    ├── pipelines.md
    ├── trigon-architecture.md
    └── internal/            # planning & strategy docs (not user-facing)
```

---

## Settings persistence

Each named container (`--name`) gets its own settings directory on the host at `~/.trigon-settings-<name>`. This holds Claude Code's OAuth token, conversation history, and configuration — it persists across container restarts.

---

## Origin

Trigon generalises [claude-in-container](https://github.com/Bergurth/claude-in-container) along three axes: provider, agent, and mode. The working `claude-code + anthropic + dev/security` implementation is the reference; the rest of the system layers on top without breaking it.

---

## License

Apache-2.0 — see [LICENSE](LICENSE).
