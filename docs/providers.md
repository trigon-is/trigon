# Providers

Triquetra decouples the agent (what talks to you) from the provider (which LLM
answers). This document covers every supported provider, how to configure it, and
the two underlying resolution mechanisms.

---

## Resolution tiers

### Tier 1 — Native Anthropic-compatible

These providers expose a `/v1/messages` endpoint that the Anthropic SDK speaks
natively. No proxy container is needed. Triquetra sets:

```
ANTHROPIC_BASE_URL=<provider endpoint>
ANTHROPIC_MODEL=<model name>
```

The agent container starts immediately with no additional services.

### Tier 2 — LiteLLM sidecar

These providers speak OpenAI format or require credential translation. Triquetra
starts a LiteLLM container in the same compose network and points the agent at it:

```
ANTHROPIC_BASE_URL=http://litellm:4000
ANTHROPIC_MODEL=<model alias in litellm config>
```

LiteLLM handles the translation. The agent is unaware of the difference.

---

## Supported providers

### `anthropic` (default)

**Tier:** direct (no redirect)  
**Required env:** `ANTHROPIC_API_KEY` or OAuth (Pro)  
**Models:** claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5, ...

```bash
./triquetra-up.sh ~/project                         # OAuth/Pro
./triquetra-up.sh ~/project --api                   # API key from ~/.anthropic_api_key
```

No `ANTHROPIC_BASE_URL` is set. Standard Claude Code behaviour.

---

### `deepseek`

**Tier:** 1 (Anthropic-compatible)  
**Required env:** `DEEPSEEK_API_KEY`  
**Models:** deepseek-chat, deepseek-reasoner  
**Endpoint:** `https://api.deepseek.com/v1`  
**Pricing (2026-06):** ~$0.87/M output tokens (deepseek-chat), $3.50/M (deepseek-reasoner)

```bash
export DEEPSEEK_API_KEY=sk-...
./triquetra-up.sh ~/project --provider deepseek
./triquetra-up.sh ~/project --provider deepseek:deepseek-reasoner  # reasoning model
```

DeepSeek exposes a native Anthropic-format API. No proxy required. Note: review
DeepSeek's privacy policy regarding training data before using with proprietary code.

---

### `openrouter/MODEL`

**Tier:** 1 (Anthropic-compatible)  
**Required env:** `OPENROUTER_API_KEY`  
**Models:** any model slug from openrouter.ai  
**Endpoint:** `https://openrouter.ai/api/v1`  
**Privacy:** ZDR (zero data retention) available on most models

```bash
export OPENROUTER_API_KEY=sk-or-...
./triquetra-up.sh ~/project --provider openrouter/google/gemini-2.5-pro
./triquetra-up.sh ~/project --provider openrouter/meta-llama/llama-3.3-70b-instruct
./triquetra-up.sh ~/project --provider openrouter/deepseek/deepseek-r1
```

OpenRouter is the recommended path for: model comparison, accessing models not
available directly, and when ZDR is required. The `/MODEL` suffix is the
OpenRouter model slug — see openrouter.ai/models for the full list.

---

### `ollama:MODEL`

**Tier:** 2 (LiteLLM sidecar)  
**Required:** Ollama running on host  
**Models:** any model pulled with `ollama pull`  
**Data leaves machine:** never

```bash
# Start Ollama on host first
ollama pull qwen2.5-coder:7b

./triquetra-up.sh ~/project --provider ollama:qwen2.5-coder:7b
./triquetra-up.sh ~/project --provider ollama:llama3.3 --air-gap
./triquetra-up.sh ~/project --provider ollama:codellama:13b --air-gap
```

The LiteLLM sidecar connects to `host.docker.internal:11434` (the host's Ollama
daemon). With `--air-gap`, the agent container has no outbound network access
— only internal compose network traffic to the LiteLLM sidecar is allowed.

**Recommended models for coding tasks (2026-06):**
- `qwen2.5-coder:7b` — fast, good quality, 7B fits on most machines
- `qwen2.5-coder:32b` — stronger, requires ~20GB VRAM
- `codellama:13b` — good for completion-style tasks
- `deepseek-coder-v2:16b` — strong reasoning, heavier

---

### `openai/MODEL`

**Tier:** 2 (LiteLLM sidecar)  
**Required env:** `OPENAI_API_KEY`  
**Models:** gpt-4o, gpt-4o-mini, o3, o3-mini, o4-mini, ...

```bash
export OPENAI_API_KEY=sk-...
./triquetra-up.sh ~/project --provider openai/gpt-4o
./triquetra-up.sh ~/project --provider openai/o3
```

---

### `bedrock/MODEL`

**Tier:** 2 (LiteLLM sidecar)  
**Required env:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`  
**Models:** anthropic.claude-sonnet-4-6, meta.llama3-3-70b-instruct-v1, ...

```bash
./triquetra-up.sh ~/project --provider bedrock/anthropic.claude-sonnet-4-6
```

Useful for teams already operating in AWS who want consolidated billing or
VPC-private inference.

---

### `litellm:CONFIG_FILE`

**Tier:** 2 (LiteLLM sidecar with custom config)  
**Required:** a valid LiteLLM YAML config file

Escape hatch for any provider or routing configuration not covered above.
Write a `litellm-config.yaml` and point Triquetra at it:

```bash
./triquetra-up.sh ~/project --provider litellm:./my-litellm-config.yaml
```

LiteLLM config reference: https://docs.litellm.ai/docs/proxy/configs

---

## Provider config files

Each built-in provider has a YAML spec in `providers/`. These are read by
`triquetra-up.sh` to resolve environment variables, base URLs, and whether the
LiteLLM sidecar is needed.

```yaml
# providers/deepseek.yml
type: anthropic-compat
base_url: https://api.deepseek.com/v1
default_model: deepseek-chat
model_map:
  fast: deepseek-chat
  smart: deepseek-reasoner
requires:
  - DEEPSEEK_API_KEY
api_key_env: DEEPSEEK_API_KEY
```

```yaml
# providers/ollama.yml
type: litellm-proxy
litellm_host: host.docker.internal
litellm_port: 11434
default_model: qwen2.5-coder:7b
requires: []        # no API key needed
notes: |
  Requires Ollama running on host. Pull models with: ollama pull MODEL
```

---

## Model aliases

Within a provider spec, `model_map` defines short aliases:

| Alias | Meaning |
|-------|---------|
| `fast` | Cheapest/fastest model from that provider |
| `smart` | Strongest model from that provider |
| `reason` | Reasoning-optimised model (where available) |

```bash
./triquetra-up.sh ~/project --provider deepseek:fast   # deepseek-chat
./triquetra-up.sh ~/project --provider deepseek:smart  # deepseek-reasoner
```

---

## Privacy considerations by provider

| Provider | Data leaves machine | Training opt-out | ZDR available |
|----------|--------------------|--------------------|---------------|
| anthropic | yes | yes (API) | no |
| deepseek | yes | unclear (review policy) | no |
| openrouter/* | yes | per-model | yes (most models) |
| ollama:* | **never** | n/a | n/a |
| openai/* | yes | yes (API) | enterprise only |
| bedrock/* | yes (to AWS) | yes | yes (enterprise) |

For sensitive or proprietary code: use `ollama:*` with `--air-gap`.

---

## Adding a new provider

1. Create `providers/myprovider.yml` following the schema above
2. If `type: anthropic-compat`: add env var handling to `triquetra-up.sh`
3. If `type: litellm-proxy`: add a LiteLLM model entry to `compose/litellm.yml`
4. Add an entry to the table in this document
5. Test with `--prompt-file` in pipeline mode
