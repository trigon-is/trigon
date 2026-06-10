#!/bin/bash
set -euo pipefail

TRIQUETRA_MODE="${TRIQUETRA_MODE:-dev}"
TRIGON_PROVIDER_TYPE="${TRIGON_PROVIDER_TYPE:-direct}"
TRIGON_PROVIDER_MODEL="${TRIGON_PROVIDER_MODEL:-}"

# XDG dirs are set by compose (XDG_CONFIG_HOME=/settings/config).
# OpenCode reads its config from $XDG_CONFIG_HOME/opencode/config.json automatically.
OPENCODE_CONFIG_DIR="${XDG_CONFIG_HOME:-/settings/config}/opencode"
OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/config.json"
mkdir -p "$OPENCODE_CONFIG_DIR"

# ── Provider config ───────────────────────────────────────────────────────────
# For 'direct' (Anthropic), OpenCode detects ANTHROPIC_API_KEY natively — no
# config file needed. For proxied/compat providers, write a config.json.

case "$TRIGON_PROVIDER_TYPE" in
  direct)
    # Native Anthropic — ANTHROPIC_API_KEY already in env, nothing to do
    ;;

  anthropic-compat)
    # Third-party Anthropic-format endpoint (e.g. OpenRouter in Anthropic mode).
    # Configure OpenCode's anthropic provider with a custom baseURL.
    MODEL="${TRIGON_PROVIDER_MODEL:-claude-sonnet-4-5}"
    cat > "$OPENCODE_CONFIG_FILE" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "anthropic/${MODEL}",
  "provider": {
    "anthropic": {
      "options": {
        "baseURL": "${ANTHROPIC_BASE_URL}"
      }
    }
  }
}
EOF
    echo "OpenCode: anthropic-compat provider config written (baseURL=${ANTHROPIC_BASE_URL})"
    ;;

  litellm-proxy)
    # LiteLLM sidecar exposes an Anthropic-compatible API at http://litellm:4000.
    # Point OpenCode's anthropic provider at the sidecar.
    # Note: ANTHROPIC_API_KEY is already set to sk-litellm-passthrough by triquetra-up.sh.
    MODEL="${TRIGON_PROVIDER_MODEL:-default-model}"
    cat > "$OPENCODE_CONFIG_FILE" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "anthropic/${MODEL}",
  "provider": {
    "anthropic": {
      "options": {
        "baseURL": "http://litellm:4000"
      }
    }
  }
}
EOF
    echo "OpenCode: litellm-proxy config written (model=${MODEL})"
    ;;
esac

# ── Pipeline mode ─────────────────────────────────────────────────────────────
# triquetra-up.sh sets PROMPT_FILE=/prompt/input.md and mounts the file there.
if [[ -n "${PROMPT_FILE:-}" && -f "$PROMPT_FILE" ]]; then
  echo "OpenCode: pipeline mode (${PROMPT_FILE})"
  exec opencode --no-tui --message "$(cat "$PROMPT_FILE")"
fi

exec opencode
