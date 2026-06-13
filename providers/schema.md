# Provider YAML Schema Reference

Each file in `providers/` defines one provider. `trigon-up.sh` reads these
at launch time to determine how to configure the container environment.

---

## Fields

### `type` (required)

| Value | Meaning |
|-------|---------|
| `direct` | No redirection. Standard Anthropic API endpoint. |
| `anthropic-compat` | Provider exposes `/v1/messages` in Anthropic format. Script sets `ANTHROPIC_BASE_URL`. No sidecar. |
| `litellm-proxy` | Provider needs translation. LiteLLM sidecar started; agent talks to `http://litellm:4000`. |

### `base_url` (anthropic-compat only, required)

The API endpoint. Injected as `ANTHROPIC_BASE_URL`.

### `default_model` (required)

Used when no model is specified in `--provider`. Injected as `ANTHROPIC_MODEL`.

### `model_map` (optional)

Short aliases for common model tiers. Conventional keys:

| Key | Meaning |
|-----|---------|
| `fast` | Cheapest/fastest model from this provider |
| `smart` | Most capable model |
| `reason` | Reasoning-optimised model (where available) |

Additional keys are allowed. Usage: `--provider deepseek:smart`.

### `api_key_env` (required)

Name of the host env var holding the API key. Empty string (`""`) if no key needed (e.g. Ollama).
The script reads this env var from the host and injects it into the container as `ANTHROPIC_API_KEY`
(for anthropic-compat) or into the LiteLLM sidecar env (for litellm-proxy).

### `requires` (required, may be empty list)

List of env var names that must be set on the host before launch. Script exits with an error
if any are missing. Typically matches `api_key_env` plus any additional credentials.

### `litellm_model_prefix` (litellm-proxy only)

String prepended to the resolved model name when passed to LiteLLM.  
Example: `"ollama/"` → LiteLLM receives `ollama/qwen2.5-coder:7b`.

### `litellm_api_base` (litellm-proxy only)

URL where LiteLLM connects to reach the upstream provider.  
Empty string for providers accessed via SDK (e.g. AWS Bedrock via boto3).

### `notes` (optional)

Human-readable string shown when this provider is selected. Useful for setup reminders.

---

## Provider flag parsing rules

The `--provider` argument is parsed as follows:

| Input form | Provider file | Model |
|------------|---------------|-------|
| `deepseek` | `providers/deepseek.yml` | `default_model` |
| `deepseek:deepseek-reasoner` | `providers/deepseek.yml` | `deepseek-reasoner` |
| `deepseek:smart` | `providers/deepseek.yml` | `model_map.smart` |
| `openrouter/google/gemini-2.5-pro` | `providers/openrouter.yml` | `google/gemini-2.5-pro` |
| `openrouter:smart` | `providers/openrouter.yml` | `model_map.smart` |
| `ollama:qwen2.5-coder:7b` | `providers/ollama.yml` | `qwen2.5-coder:7b` |
| `openai/gpt-4o` | `providers/openai.yml` | `gpt-4o` |
| `bedrock/anthropic.claude-sonnet-4-6` | `providers/bedrock.yml` | `anthropic.claude-sonnet-4-6` |
| `litellm:./my-config.yaml` | *(no provider file)* | *(from litellm config)* |

**Parsing algorithm:**

1. If input starts with `openrouter/` or `bedrock/` or `openai/`: split at first `/`.
   Provider = left side, model = right side (may contain further `/`).
2. Otherwise: split at first `:`. Provider = left side, model = right side (if present).
3. Look up `providers/<provider>.yml`.
4. If model is empty: use `default_model`.
5. If model matches a key in `model_map`: resolve to the aliased value.
6. Set `ANTHROPIC_MODEL` to the resolved model name.

---

## LiteLLM config generation (litellm-proxy)

`trigon-up.sh` generates a minimal LiteLLM config at runtime into a temp file
and mounts it into the sidecar container. The generated config looks like:

```yaml
model_list:
  - model_name: <litellm_model_prefix><resolved_model>
    litellm_params:
      model: <litellm_model_prefix><resolved_model>
      api_base: <litellm_api_base>       # omitted if empty
      api_key: <api_key_value>           # omitted if api_key_env is empty
```

For `litellm:./my-config.yaml`, the user-supplied file is mounted directly with no generation.
