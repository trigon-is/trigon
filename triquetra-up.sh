#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"
COMPOSE_DIR="${SCRIPT_DIR}/compose"

# ── Argument collection ───────────────────────────────────────────────────────
# Positional args before the first flag are project paths.
PROJECT_PATHS=()
FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --*) FLAGS+=("$arg") ;;
    *)   [[ ${#FLAGS[@]} -eq 0 ]] && PROJECT_PATHS+=("$arg") || FLAGS+=("$arg") ;;
  esac
done

[[ ${#PROJECT_PATHS[@]} -eq 0 ]] && PROJECT_PATHS+=("$(pwd)")
if [[ ${#PROJECT_PATHS[@]} -gt 5 ]]; then
  echo "Error: Maximum 5 project directories supported" >&2; exit 1
fi

for i in "${!PROJECT_PATHS[@]}"; do
  path="${PROJECT_PATHS[$i]}"
  [[ ! -d "$path" ]] && { echo "Error: Directory not found: $path" >&2; exit 1; }
  abs="$(cd "$path" && pwd)"
  PROJECT_PATHS[$i]="$abs"
  [[ $i -eq 0 ]] && export PROJECT_ROOT="$abs"
  export "PROJECT_ROOT_$((i+1))"="$abs"
done

# ── Defaults ──────────────────────────────────────────────────────────────────
PROVIDER="anthropic"
AGENT="claude-code"
MODE="dev"
NAME=""
YOLO=0
ROOT_MODE=0
PLAYWRIGHT=0
PLAYWRIGHT_HEADLESS=0
USE_API_KEY=0
AIR_GAP=0
PROMPT_FILE=""
MAX_BUDGET_USD=""

# ── Flag parsing ──────────────────────────────────────────────────────────────
i=0
while [[ $i -lt ${#FLAGS[@]} ]]; do
  arg="${FLAGS[$i]}"
  case "$arg" in
    --provider=*) PROVIDER="${arg#--provider=}" ;;
    --provider)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --provider requires a value" >&2; exit 1; }
      PROVIDER="${FLAGS[$i]}" ;;
    --agent=*)    AGENT="${arg#--agent=}" ;;
    --agent)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --agent requires a value" >&2; exit 1; }
      AGENT="${FLAGS[$i]}" ;;
    --mode=*)     MODE="${arg#--mode=}" ;;
    --mode)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --mode requires a value" >&2; exit 1; }
      MODE="${FLAGS[$i]}" ;;
    --name=*)     NAME="${arg#--name=}" ;;
    --name)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --name requires a value" >&2; exit 1; }
      NAME="${FLAGS[$i]}" ;;
    --prompt-file=*) PROMPT_FILE="${arg#--prompt-file=}" ;;
    --prompt-file)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --prompt-file requires a value" >&2; exit 1; }
      PROMPT_FILE="${FLAGS[$i]}" ;;
    --max-budget=*)  MAX_BUDGET_USD="${arg#--max-budget=}" ;;
    --max-budget)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --max-budget requires a value" >&2; exit 1; }
      MAX_BUDGET_USD="${FLAGS[$i]}" ;;
    --yolo)        YOLO=1 ;;
    --root)        ROOT_MODE=1 ;;
    --playwright|--playwrite) PLAYWRIGHT=1 ;;
    --playwright-headless)    PLAYWRIGHT_HEADLESS=1 ;;
    --api)         USE_API_KEY=1 ;;
    --air-gap)    AIR_GAP=1 ;;
    --security)    MODE="security" ;;  # backward compat alias for --mode security
    *)             echo "Warning: unknown flag '$arg'" >&2 ;;
  esac
  i=$((i+1))
done

# ── Validate agent ────────────────────────────────────────────────────────────
if [[ "$AGENT" != "claude-code" ]]; then
  echo "Error: agent '${AGENT}' not yet supported. Only claude-code is available." >&2
  exit 1
fi

# ── Default container name ────────────────────────────────────────────────────
[[ -z "$NAME" ]] && NAME="triquetra-${AGENT}"

# ── Provider flag parsing ─────────────────────────────────────────────────────
# Slash-prefix forms: openrouter/org/model  bedrock/model  openai/model
# Colon forms:        deepseek:smart  ollama:qwen2.5:7b  litellm:/path/config.yaml
PROVIDER_NAME=""
MODEL_SPEC=""
MODEL_SPECIFIED=0

case "$PROVIDER" in
  openrouter/*) PROVIDER_NAME="openrouter"; MODEL_SPEC="${PROVIDER#openrouter/}"; MODEL_SPECIFIED=1 ;;
  bedrock/*)    PROVIDER_NAME="bedrock";    MODEL_SPEC="${PROVIDER#bedrock/}";    MODEL_SPECIFIED=1 ;;
  openai/*)     PROVIDER_NAME="openai";     MODEL_SPEC="${PROVIDER#openai/}";     MODEL_SPECIFIED=1 ;;
  litellm:*)    PROVIDER_NAME="litellm";    MODEL_SPEC="${PROVIDER#litellm:}";    MODEL_SPECIFIED=0 ;;
  *:*)          PROVIDER_NAME="${PROVIDER%%:*}"; MODEL_SPEC="${PROVIDER#*:}";     MODEL_SPECIFIED=1 ;;
  *)            PROVIDER_NAME="$PROVIDER";  MODEL_SPEC="" ;;
esac

# ── Provider YAML loading (embedded Python3, no external YAML dep) ────────────
PROVIDER_TYPE=""
PROVIDER_BASE_URL=""
PROVIDER_MODEL=""
PROVIDER_API_KEY_ENV=""
PROVIDER_LITELLM_PREFIX=""
PROVIDER_LITELLM_API_BASE=""
PROVIDER_REQUIRES=""
PROVIDER_NOTES=""
LITELLM_USER_CONFIG=""

if [[ "$PROVIDER_NAME" == "litellm" ]]; then
  PROVIDER_TYPE="litellm-proxy"
  LITELLM_USER_CONFIG="$MODEL_SPEC"
  [[ ! -f "$LITELLM_USER_CONFIG" ]] && { echo "Error: litellm config not found: $LITELLM_USER_CONFIG" >&2; exit 1; }
else
  PROVIDER_FILE="${PROVIDERS_DIR}/${PROVIDER_NAME}.yml"
  if [[ ! -f "$PROVIDER_FILE" ]]; then
    echo "Error: Unknown provider '${PROVIDER_NAME}'. No file: ${PROVIDER_FILE}" >&2
    echo "Available: $(ls "${PROVIDERS_DIR}"/*.yml 2>/dev/null | xargs -n1 basename | sed 's/\.yml//' | tr '\n' ' ')" >&2
    exit 1
  fi

  eval "$(python3 - "$PROVIDER_FILE" "$MODEL_SPEC" <<'PYEOF'
import sys

path = sys.argv[1]
model_spec = sys.argv[2] if len(sys.argv) > 2 else ""

data = {
    'type': '', 'base_url': '', 'default_model': '',
    'api_key_env': '', 'litellm_model_prefix': '',
    'litellm_api_base': '', 'notes': '',
    'model_map': {}, 'requires': [],
}

section = None
with open(path) as f:
    for line in f:
        line = line.rstrip()
        if not line or line.lstrip().startswith('#'):
            continue
        if line[:1] in (' ', '\t'):
            s = line.strip()
            if section == 'model_map' and ':' in s:
                k, _, v = s.partition(':')
                data['model_map'][k.strip()] = v.strip().strip('"\'')
            elif section == 'requires' and s.startswith('- '):
                data['requires'].append(s[2:].strip())
        else:
            if ':' in line:
                k, _, v = line.partition(':')
                k = k.strip()
                v = v.strip().strip('"\'')
                if k in data and isinstance(data[k], (list, dict)):
                    section = k
                else:
                    data[k] = v
                    section = None

model = model_spec or data.get('default_model', '')
if model in data['model_map']:
    model = data['model_map'][model]

def sh(v):
    v = str(v) if v else ''
    return "'" + v.replace("'", "'\\''") + "'"

print(f"PROVIDER_TYPE={sh(data.get('type',''))}")
print(f"PROVIDER_BASE_URL={sh(data.get('base_url',''))}")
print(f"PROVIDER_MODEL={sh(model)}")
print(f"PROVIDER_API_KEY_ENV={sh(data.get('api_key_env',''))}")
print(f"PROVIDER_LITELLM_PREFIX={sh(data.get('litellm_model_prefix',''))}")
print(f"PROVIDER_LITELLM_API_BASE={sh(data.get('litellm_api_base',''))}")
print(f"PROVIDER_REQUIRES={sh(' '.join(data.get('requires',[])))}")
print(f"PROVIDER_NOTES={sh(data.get('notes',''))}")
PYEOF
  )"
fi

# ── Validate required env vars ────────────────────────────────────────────────
for req_var in $PROVIDER_REQUIRES; do
  if [[ -z "${!req_var:-}" ]]; then
    echo "Error: provider '${PROVIDER_NAME}' requires \$$req_var to be set on the host." >&2
    exit 1
  fi
done

echo "Provider: ${PROVIDER_NAME} (${PROVIDER_TYPE}), model: ${PROVIDER_MODEL:-default}"
[[ -n "${PROVIDER_NOTES:-}" ]] && echo "Note: $PROVIDER_NOTES"

# ── Docker Compose detection ──────────────────────────────────────────────────
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "Error: Docker Compose not found." >&2; exit 1
fi

# ── User/group ────────────────────────────────────────────────────────────────
[[ $ROOT_MODE -eq 1 ]] \
  && { export LOCAL_UID=0; export LOCAL_GID=0; } \
  || { export LOCAL_UID="$(id -u)"; export LOCAL_GID="$(id -g)"; }

# ── Settings directory (persisted across runs, keyed by container name) ───────
CLAUDE_SETTINGS_DIR="${CLAUDE_SETTINGS_DIR:-$HOME/.triquetra-settings${NAME:+-$NAME}}"
mkdir -p "$CLAUDE_SETTINGS_DIR"
export CLAUDE_SETTINGS_DIR

# ── Compose file assembly ─────────────────────────────────────────────────────
SERVICE_NAME="triquetra"
COMPOSE_FILES=("-f" "${COMPOSE_DIR}/base.yml")

# ── Image selection ───────────────────────────────────────────────────────────
export TRIQUETRA_IMAGE="${AGENT}-${MODE}:latest"

# ── Mode setup ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "security" ]]; then
  SECURITY_RESULTS_DIR="${SECURITY_RESULTS_DIR:-$PWD/security-results}"
  WORDLISTS_DIR="${WORDLISTS_DIR:-$PWD/wordlists}"
  mkdir -p "$SECURITY_RESULTS_DIR" "$WORDLISTS_DIR"
  export SECURITY_RESULTS_DIR WORDLISTS_DIR
  COMPOSE_FILES+=("-f" "${COMPOSE_DIR}/security.yml")
  echo "Mode: security | Results: $SECURITY_RESULTS_DIR"
fi

# ── Temp file registry ────────────────────────────────────────────────────────
TEMP_FILES=()
cleanup() { for f in "${TEMP_FILES[@]:-}"; do [[ -f "${f:-}" ]] && rm -f "$f"; done; }
trap cleanup EXIT INT TERM

# ── Tier-2: LiteLLM sidecar ──────────────────────────────────────────────────
if [[ "$PROVIDER_TYPE" == "litellm-proxy" ]]; then
  if [[ $PLAYWRIGHT -eq 1 ]]; then
    echo "Error: --playwright and a tier-2 provider (LiteLLM sidecar) cannot be combined." >&2
    echo "  Playwright needs network_mode=host; LiteLLM needs a shared compose network." >&2
    exit 1
  fi

  # Build LiteLLM config YAML (unless user supplied their own)
  if [[ -n "$LITELLM_USER_CONFIG" ]]; then
    LITELLM_CONFIG="$LITELLM_USER_CONFIG"
  else
    LITELLM_CONFIG="$(mktemp --suffix=.yml)"
    TEMP_FILES+=("$LITELLM_CONFIG")
    FULL_MODEL="${PROVIDER_LITELLM_PREFIX}${PROVIDER_MODEL}"
    {
      printf 'model_list:\n'
      printf '  - model_name: %s\n' "$PROVIDER_MODEL"
      printf '    litellm_params:\n'
      printf '      model: %s\n' "$FULL_MODEL"
      [[ -n "$PROVIDER_LITELLM_API_BASE" ]] && printf '      api_base: %s\n' "$PROVIDER_LITELLM_API_BASE"
    } > "$LITELLM_CONFIG"
  fi
  export LITELLM_CONFIG

  # Generate compose fragment for the sidecar
  LITELLM_COMPOSE="$(mktemp --suffix=.yml)"
  TEMP_FILES+=("$LITELLM_COMPOSE")
  cat > "$LITELLM_COMPOSE" <<COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    depends_on:
      litellm:
        condition: service_healthy

  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    volumes:
      - ${LITELLM_CONFIG}:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    environment:
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
      - AWS_REGION=${AWS_REGION:-us-east-1}
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')\" 2>/dev/null || exit 1"]
      interval: 3s
      timeout: 5s
      retries: 20
      start_period: 15s
COMPOSE_EOF
  COMPOSE_FILES+=("-f" "$LITELLM_COMPOSE")
fi

# ── API key resolution ────────────────────────────────────────────────────────
EXTRA_ARGS=()
API_KEY_VALUE=""

if [[ -n "$PROVIDER_API_KEY_ENV" ]]; then
  if [[ -n "${!PROVIDER_API_KEY_ENV:-}" ]]; then
    # Already in environment
    API_KEY_VALUE="${!PROVIDER_API_KEY_ENV}"
  elif [[ $USE_API_KEY -eq 1 ]]; then
    # --api: try ~/.{provider}_api_key
    KEY_FILE="${HOME}/.${PROVIDER_NAME}_api_key"
    if [[ ! -f "$KEY_FILE" ]]; then
      echo "Error: --api set but \$$PROVIDER_API_KEY_ENV is not set and $KEY_FILE not found." >&2
      exit 1
    fi
    API_KEY_VALUE="$(cat "$KEY_FILE")"
  elif [[ "$PROVIDER_TYPE" != "direct" ]]; then
    echo "Warning: provider '${PROVIDER_NAME}' requires \$$PROVIDER_API_KEY_ENV. Set it or use --api." >&2
  fi
elif [[ $USE_API_KEY -eq 1 ]] && [[ "$PROVIDER_TYPE" == "direct" ]]; then
  # Anthropic direct with --api flag
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    API_KEY_VALUE="$ANTHROPIC_API_KEY"
  else
    KEY_FILE="${HOME}/.anthropic_api_key"
    [[ ! -f "$KEY_FILE" ]] && { echo "Error: --api set but ANTHROPIC_API_KEY not set and $KEY_FILE not found." >&2; exit 1; }
    API_KEY_VALUE="$(cat "$KEY_FILE")"
  fi
fi

# Inject key into the right place
if [[ -n "$API_KEY_VALUE" ]]; then
  case "$PROVIDER_TYPE" in
    direct|anthropic-compat)
      EXTRA_ARGS+=(-e "ANTHROPIC_API_KEY=${API_KEY_VALUE}")
      echo "API key loaded (\$$PROVIDER_API_KEY_ENV) — API billing active."
      ;;
    litellm-proxy)
      # Append key to the generated litellm config (no-op for user-supplied config)
      if [[ -z "$LITELLM_USER_CONFIG" ]]; then
        printf '      api_key: %s\n' "$API_KEY_VALUE" >> "$LITELLM_CONFIG"
      fi
      ;;
  esac
fi

# ── Provider env var injection ────────────────────────────────────────────────
case "$PROVIDER_TYPE" in
  direct)
    # Only override model if user explicitly specified one
    [[ $MODEL_SPECIFIED -eq 1 ]] && EXTRA_ARGS+=(-e "ANTHROPIC_MODEL=${PROVIDER_MODEL}")
    ;;
  anthropic-compat)
    EXTRA_ARGS+=(-e "ANTHROPIC_BASE_URL=${PROVIDER_BASE_URL}")
    EXTRA_ARGS+=(-e "ANTHROPIC_MODEL=${PROVIDER_MODEL}")
    ;;
  litellm-proxy)
    EXTRA_ARGS+=(-e "ANTHROPIC_BASE_URL=http://litellm:4000")
    EXTRA_ARGS+=(-e "ANTHROPIC_MODEL=${PROVIDER_MODEL}")
    # Claude Code requires a non-empty API key even for local/proxied endpoints
    EXTRA_ARGS+=(-e "ANTHROPIC_API_KEY=${API_KEY_VALUE:-sk-litellm-passthrough}")
    ;;
esac

# ── Prompt file ───────────────────────────────────────────────────────────────
if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
  [[ ! -f "$PROMPT_FILE" ]] && { echo "Error: prompt file not found: $PROMPT_FILE" >&2; exit 1; }
  EXTRA_ARGS+=(-v "${PROMPT_FILE}:/prompt/input.md:ro")
  echo "Prompt file: $PROMPT_FILE (non-interactive mode)"
fi

# ── Playwright MCP ────────────────────────────────────────────────────────────
if [[ $PLAYWRIGHT -eq 1 ]]; then
  MCP_CONFIG="${PROJECT_ROOT}/.mcp.json"
  [[ -f "$MCP_CONFIG" ]] && cp "$MCP_CONFIG" "${MCP_CONFIG}.backup"
  cp "${COMPOSE_DIR}/mcp-config-template.json" "$MCP_CONFIG"
  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"
  echo "Playwright MCP: config written — connecting to host Chrome on localhost:9222"
  echo "Make sure Chrome is running with: google-chrome --remote-debugging-port=9222"

  PLAYWRIGHT_COMPOSE="$(mktemp --suffix=.yml)"
  TEMP_FILES+=("$PLAYWRIGHT_COMPOSE")
  cat > "$PLAYWRIGHT_COMPOSE" <<COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    network_mode: "host"
COMPOSE_EOF
  COMPOSE_FILES+=("-f" "$PLAYWRIGHT_COMPOSE")
  export PLAYWRIGHT_ENABLED=1
else
  export PLAYWRIGHT_ENABLED=0
fi

# ── --playwright-headless ────────────────────────────────────────────────────
if [[ $PLAYWRIGHT_HEADLESS -eq 1 ]]; then
  if [[ $PLAYWRIGHT -eq 1 ]]; then
    echo "Error: --playwright and --playwright-headless cannot both be specified." >&2; exit 1
  fi


  MCP_CONFIG="${PROJECT_ROOT}/.mcp.json"
  [[ -f "$MCP_CONFIG" ]] && cp "$MCP_CONFIG" "${MCP_CONFIG}.backup"
  cp "${COMPOSE_DIR}/mcp-config-headless.json" "$MCP_CONFIG"
  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"
  echo "Playwright MCP (headless): config written — Chromium runs inside the container"

  PLAYWRIGHT_HEADLESS_COMPOSE="$(mktemp --suffix=.yml)"
  TEMP_FILES+=("$PLAYWRIGHT_HEADLESS_COMPOSE")
  cat > "$PLAYWRIGHT_HEADLESS_COMPOSE" <<COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    ipc: host
    cap_add:
      - SYS_PTRACE
    environment:
      - PLAYWRIGHT_HEADLESS_ENABLED=1
      - PLAYWRIGHT_BROWSERS_PATH=/usr/local/playwright-browsers
COMPOSE_EOF
  COMPOSE_FILES+=("-f" "$PLAYWRIGHT_HEADLESS_COMPOSE")
  export PLAYWRIGHT_ENABLED=1
fi

# ── --air-gap ─────────────────────────────────────────────────────────────────
if [[ $AIR_GAP -eq 1 ]]; then
  if [[ $PLAYWRIGHT -eq 1 ]]; then
    echo "Error: --air-gap and --playwright are incompatible." >&2
    echo "  --playwright uses network_mode=host, which cannot be isolated." >&2
    exit 1
  fi
  if [[ "$PROVIDER_TYPE" == "direct" || "$PROVIDER_TYPE" == "anthropic-compat" ]]; then
    echo "Error: --air-gap requires a local provider (e.g. --provider ollama:MODEL)." >&2
    echo "  '${PROVIDER_NAME}' (${PROVIDER_TYPE}) needs outbound internet to reach its API." >&2
    exit 1
  fi
  if [[ $PLAYWRIGHT_HEADLESS -eq 1 ]]; then
    echo "Warning: --air-gap with --playwright-headless: Chromium inside the container" >&2
    echo "  cannot reach external URLs. Intranet and local targets only." >&2
  fi

  AIR_GAP_COMPOSE="$(mktemp --suffix=.yml)"
  TEMP_FILES+=("$AIR_GAP_COMPOSE")

  if [[ "$PROVIDER_TYPE" == "litellm-proxy" ]]; then
    # Agent: air_gap only (no internet). LiteLLM: air_gap + default (needs host for Ollama).
    cat > "$AIR_GAP_COMPOSE" <<COMPOSE_EOF
networks:
  air_gap:
    driver: bridge
    internal: true

services:
  ${SERVICE_NAME}:
    networks:
      - air_gap
  litellm:
    networks:
      - air_gap
      - default
COMPOSE_EOF
  else
    cat > "$AIR_GAP_COMPOSE" <<COMPOSE_EOF
networks:
  air_gap:
    driver: bridge
    internal: true

services:
  ${SERVICE_NAME}:
    networks:
      - air_gap
COMPOSE_EOF
  fi

  COMPOSE_FILES+=("-f" "$AIR_GAP_COMPOSE")
  echo "Air-gap: agent container isolated — no outbound internet."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "Mounting:"
for i in "${!PROJECT_PATHS[@]}"; do
  [[ $i -eq 0 ]] && echo "  ${PROJECT_PATHS[$i]} → /app" \
                 || echo "  ${PROJECT_PATHS[$i]} → /app_$((i+1))"
done
echo "Agent: ${AGENT} | Provider: ${PROVIDER_NAME} | Mode: ${MODE} | Model: ${PROVIDER_MODEL:-default}"
echo "Container: ${NAME} | Settings: ${CLAUDE_SETTINGS_DIR}"
[[ $AIR_GAP -eq 1 ]] && echo "Network: air-gapped"

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ -n "$PROMPT_FILE" ]]; then
  CLAUDE_ARGS=(-p "$(cat "$PROMPT_FILE")" --no-session-persistence)
  [[ $YOLO -eq 1 ]] && CLAUDE_ARGS+=(--dangerously-skip-permissions)
  [[ -n "$MAX_BUDGET_USD" ]] && CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
  "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
    "${EXTRA_ARGS[@]}" "$SERVICE_NAME" claude "${CLAUDE_ARGS[@]}"
else
  if [[ $YOLO -eq 1 ]]; then
    echo "YOLO: passing --dangerously-skip-permissions to claude"
    "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
      "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME" claude --dangerously-skip-permissions
  else
    "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
      "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME"
  fi
fi
