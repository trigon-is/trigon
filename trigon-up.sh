#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"
COMPOSE_DIR="${SCRIPT_DIR}/compose"
LIB_DIR="${SCRIPT_DIR}/lib"

# Portable mktemp with a .yml suffix: BSD mktemp (macOS) only randomizes a
# trailing XXXXXX, unlike GNU mktemp's --suffix flag.
mktemp_yml() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/trigon.XXXXXX")"
  mv "$f" "$f.yml"
  echo "$f.yml"
}

# ── Mount deny-list (docs/threat-model.md G1) ─────────────────────────────────
# Prints why a path must not be bind-mounted and returns 0, or returns 1 if the
# path is fine. Paths arrive here already symlink-resolved (pwd -P), so a
# symlink inside an allowed directory cannot dodge the check.
mount_denied_reason() {
  local p="$1"
  local home=""
  [[ -d "${HOME:-}" ]] && home="$(cd "$HOME" && pwd -P)"

  [[ "$p" == "/" ]] && { echo "the filesystem root"; return 0; }
  [[ "$p" == "/home" || "$p" == "/Users" ]] && { echo "the parent of all home directories"; return 0; }
  [[ -n "$home" && "$p" == "$home" ]] && { echo "your home directory"; return 0; }

  local d
  for d in /etc /root /boot /sys /proc /dev /run /var/run /var/lib; do
    [[ "$p" == "$d" || "$p" == "$d"/* ]] && { echo "system directory $d"; return 0; }
  done

  if [[ -n "$home" ]]; then
    for d in .ssh .aws .gnupg .kube .docker .azure .claude .config/gh .config/gcloud; do
      [[ "$p" == "$home/$d" || "$p" == "$home/$d"/* ]] && { echo "credential directory ~/$d"; return 0; }
    done
    [[ "$p" == "$home"/.trigon-settings* ]] && { echo "a Trigon settings directory (holds OAuth tokens)"; return 0; }
  fi
  return 1
}

usage() {
  cat <<'USAGE'
Usage: trigon-up.sh [PROJECT_PATH ...] [FLAGS]

Project paths:
  One or more directories to mount. First → /app, subsequent → /app_2 ... /app_5.
  Defaults to the current directory. Maximum 5.

Provider:
  --provider NAME       anthropic (default), deepseek[:MODEL], openrouter/MODEL,
                        ollama:MODEL, openai/MODEL, bedrock/MODEL,
                        litellm:CONFIG_FILE. See providers/*.yml.

Agent:
  --agent NAME          claude-code (default), opencode

Mode:
  --mode NAME           dev (default), security
  --security            Alias for --mode security (backward compat)

Session:
  --name NAME           Container name; also keys the settings dir
                        ~/.trigon-settings-<name> (default: trigon-<agent>)
  --yolo                Skip agent permission prompts (claude-code only)
  --root                Run container as root

Network / browser:
  --playwright          Playwright MCP via host Chrome on localhost:9222
                        (switches container to host networking)
  --playwright-headless Playwright MCP with headless Chromium inside the container
  --mcp NAME=URL        Attach an external HTTP MCP server (repeatable). Adds a
                        host-gateway route so a server on the host is reachable at
                        host.docker.internal (e.g.
                        --mcp palladium-gm=http://host.docker.internal:8000/mcp/).
                        NOTE: servers mounted under a Starlette/FastMCP sub-path
                        (e.g. mounted at "/mcp") require a TRAILING SLASH on the URL
                        — without it the request can fall through to the parent app.
                        Merges into the project .mcp.json (restored on exit). May be
                        combined with --playwright/--playwright-headless (servers are
                        merged). Under --playwright (host networking) reach the host as
                        127.0.0.1, not host.docker.internal.
  --mcp-key VALUE       Bearer token for --mcp servers; sent as
                        "Authorization: Bearer VALUE". Passed via env so the secret
                        is not written into .mcp.json.
  --air-gap             Block outbound internet from the agent container
                        (requires a local provider, e.g. --provider ollama:MODEL)

API / billing:
  --api                 Inject API key for the selected provider (env var from
                        provider YAML, falling back to ~/.{provider}_api_key)
  --max-budget USD      Cap API spend (pipeline runs, claude-code only)

Pipeline:
  --prompt-file PATH    Non-interactive: run the prompt, exit on completion

Safety (see docs/threat-model.md):
  --allow-unsafe-mount  Override the mount deny-list (/, $HOME, /etc, credential
                        directories like ~/.ssh, ...) and mount anyway (G1)
  --allow-metadata      Proceed with --playwright even when the cloud metadata
                        service (169.254.169.254) is reachable from this host (G3)

Help:
  --dry-run             Resolve provider, assemble compose files and env, print
                        the command that would run, then exit — no container is
                        started. Useful for debugging and tests.
  -h, --help            Show this help and exit
USAGE
  exit 0
}

# ── Argument collection ───────────────────────────────────────────────────────
# Positional args before the first flag are project paths.
PROJECT_PATHS=()
FLAGS=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
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
  # -P resolves symlinks so the mount deny-list below sees the real target.
  abs="$(cd "$path" && pwd -P)"
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
MCP_SERVERS=()
MCP_KEY=""
DRY_RUN=0
ALLOW_UNSAFE_MOUNT=0
ALLOW_METADATA=0

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
    --mcp=*)      MCP_SERVERS+=("${arg#--mcp=}") ;;
    --mcp)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --mcp requires NAME=URL" >&2; exit 1; }
      MCP_SERVERS+=("${FLAGS[$i]}") ;;
    --mcp-key=*)  MCP_KEY="${arg#--mcp-key=}" ;;
    --mcp-key)
      i=$((i+1)); [[ $i -lt ${#FLAGS[@]} ]] || { echo "Error: --mcp-key requires a value" >&2; exit 1; }
      MCP_KEY="${FLAGS[$i]}" ;;
    --api)         USE_API_KEY=1 ;;
    --air-gap)    AIR_GAP=1 ;;
    --allow-unsafe-mount) ALLOW_UNSAFE_MOUNT=1 ;;
    --allow-metadata)     ALLOW_METADATA=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --security)    MODE="security" ;;  # backward compat alias for --mode security
    *)             echo "Warning: unknown flag '$arg'" >&2 ;;
  esac
  i=$((i+1))
done

# ── Mount safety (threat model G1) ────────────────────────────────────────────
for p in "${PROJECT_PATHS[@]}"; do
  if reason="$(mount_denied_reason "$p")"; then
    if [[ $ALLOW_UNSAFE_MOUNT -eq 1 ]]; then
      echo "Warning: mounting $p — $reason (--allow-unsafe-mount)." >&2
    else
      echo "Error: refusing to mount $p — $reason." >&2
      echo "  The agent would get your read/write access to that entire tree" >&2
      echo "  (docs/threat-model.md G1). Pass --allow-unsafe-mount to override." >&2
      exit 1
    fi
  fi
done

# ── Validate agent ────────────────────────────────────────────────────────────
case "$AGENT" in
  claude-code) ;;
  opencode)
    if [[ "$MODE" != "dev" ]]; then
      echo "Error: --agent opencode currently only supports --mode dev" >&2; exit 1
    fi
    ;;
  *) echo "Error: unknown agent '${AGENT}'. Valid: claude-code, opencode" >&2; exit 1 ;;
esac

# ── Default container name ────────────────────────────────────────────────────
[[ -z "$NAME" ]] && NAME="trigon-${AGENT}"

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
PROVIDER_SUPPORTS_THINKING=""
LITELLM_USER_CONFIG=""

if [[ "$PROVIDER_NAME" == "litellm" ]]; then
  PROVIDER_TYPE="litellm-proxy"
  LITELLM_USER_CONFIG="$MODEL_SPEC"
  [[ ! -f "$LITELLM_USER_CONFIG" ]] && { echo "Error: litellm config not found: $LITELLM_USER_CONFIG" >&2; exit 1; }
else
  PROVIDER_FILE="${PROVIDERS_DIR}/${PROVIDER_NAME}.yml"
  if [[ ! -f "$PROVIDER_FILE" ]]; then
    echo "Error: Unknown provider '${PROVIDER_NAME}'. No file: ${PROVIDER_FILE}" >&2
    AVAILABLE=""
    for f in "${PROVIDERS_DIR}"/*.yml; do
      [[ -e "$f" ]] || continue
      AVAILABLE+="$(basename "$f" .yml) "
    done
    echo "Available: ${AVAILABLE}" >&2
    exit 1
  fi

  # Parse the provider YAML (see lib/parse_provider.py) into PROVIDER_* vars.
  PROVIDER_VARS="$(python3 "${LIB_DIR}/parse_provider.py" "$PROVIDER_FILE" "$MODEL_SPEC")"
  eval "$PROVIDER_VARS"
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

# ── User/group ────────────────────────────────────────────────────────────────
if [[ $ROOT_MODE -eq 1 ]]; then
  export LOCAL_UID=0
  export LOCAL_GID=0
else
  LOCAL_UID="$(id -u)"
  LOCAL_GID="$(id -g)"
  export LOCAL_UID LOCAL_GID
fi

# ── Runtime hardening defaults (threat model G7) ──────────────────────────────
# compose/base.yml drops all capabilities, sets no-new-privileges, and applies
# these resource limits. Override per run via environment, e.g.
# TRIGON_MEM_LIMIT=16g TRIGON_CPUS=8 ./trigon-up.sh ...
export TRIGON_PIDS_LIMIT="${TRIGON_PIDS_LIMIT:-4096}"
export TRIGON_MEM_LIMIT="${TRIGON_MEM_LIMIT:-8g}"
if [[ -z "${TRIGON_CPUS:-}" ]]; then
  # Default the CPU cap to all host cores: bounded, but no effective throttle.
  TRIGON_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
fi
export TRIGON_CPUS

# ── Settings directory (persisted across runs, keyed by container name) ───────
CLAUDE_SETTINGS_DIR="${CLAUDE_SETTINGS_DIR:-$HOME/.trigon-settings${NAME:+-$NAME}}"
mkdir -p "$CLAUDE_SETTINGS_DIR"
export CLAUDE_SETTINGS_DIR

# ── Compose file assembly ─────────────────────────────────────────────────────
SERVICE_NAME="trigon"
COMPOSE_FILES=("-f" "${COMPOSE_DIR}/base.yml")

# ── Image selection ───────────────────────────────────────────────────────────
export TRIGON_IMAGE="${AGENT}-${MODE}:latest"

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
# MCP_CONFIG_WRITTEN: set when a Playwright flag writes .mcp.json into the
# project root, so we can restore/remove it on exit instead of leaving litter.
TEMP_FILES=()
MCP_CONFIG_WRITTEN=""
cleanup() {
  for f in "${TEMP_FILES[@]:-}"; do [[ -f "${f:-}" ]] && rm -f "$f"; done
  if [[ -n "$MCP_CONFIG_WRITTEN" ]]; then
    if [[ -f "${MCP_CONFIG_WRITTEN}.backup" ]]; then
      mv "${MCP_CONFIG_WRITTEN}.backup" "$MCP_CONFIG_WRITTEN"
    else
      rm -f "$MCP_CONFIG_WRITTEN"
    fi
  fi
}
trap cleanup EXIT INT TERM

# ── --root: restore baseline capabilities (threat model G7) ───────────────────
# base.yml drops ALL capabilities. The non-root default user needs none of them
# back, but root mode exists largely to install packages, and dpkg/apt/npm need
# the classic file-ownership/uid capabilities. Still far below Docker's default set.
if [[ $ROOT_MODE -eq 1 ]]; then
  ROOT_COMPOSE="$(mktemp_yml)"
  TEMP_FILES+=("$ROOT_COMPOSE")
  cat > "$ROOT_COMPOSE" <<COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - FSETID
      - KILL
      - SETGID
      - SETUID
      - SETPCAP
COMPOSE_EOF
  COMPOSE_FILES+=("-f" "$ROOT_COMPOSE")
  echo "Root: running as root — baseline file/uid capabilities restored (threat-model G7)"
fi

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
    LITELLM_CONFIG="$(mktemp_yml)"
    TEMP_FILES+=("$LITELLM_CONFIG")
    FULL_MODEL="${PROVIDER_LITELLM_PREFIX}${PROVIDER_MODEL}"
    {
      printf 'model_list:\n'
      printf '  - model_name: %s\n' "$PROVIDER_MODEL"
      printf '    litellm_params:\n'
      printf '      model: %s\n' "$FULL_MODEL"
      [[ -n "$PROVIDER_LITELLM_API_BASE" ]] && printf '      api_base: %s\n' "$PROVIDER_LITELLM_API_BASE"
      if [[ "${PROVIDER_SUPPORTS_THINKING:-}" == "false" ]]; then
        printf '    model_info:\n'
        printf '      supports_thinking: false\n'
      fi
      printf 'litellm_settings:\n'
      printf '  drop_params: true\n'
    } > "$LITELLM_CONFIG"
  fi
  export LITELLM_CONFIG

  # Generate compose fragment for the sidecar
  LITELLM_COMPOSE="$(mktemp_yml)"
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
    extra_hosts:
      - "host.docker.internal:host-gateway"
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
    # Both Claude Code and OpenCode require a non-empty API key for proxied endpoints
    EXTRA_ARGS+=(-e "ANTHROPIC_API_KEY=${API_KEY_VALUE:-sk-litellm-passthrough}")
    ;;
esac

# Expose provider type and model to agent wrappers (used by opencode wrapper.sh
# to generate the correct native provider config)
EXTRA_ARGS+=(-e "TRIGON_PROVIDER_TYPE=${PROVIDER_TYPE}")
EXTRA_ARGS+=(-e "TRIGON_PROVIDER_MODEL=${PROVIDER_MODEL}")

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
  MCP_CONFIG_WRITTEN="$MCP_CONFIG"
  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"
  echo "Playwright MCP: config written — connecting to host Chrome on localhost:9222"
  echo "Make sure Chrome is running with: google-chrome --remote-debugging-port=9222"
  echo "WARNING: --playwright switches the container to HOST networking — the agent" >&2
  echo "  shares the host's network namespace (localhost services, LAN, cloud metadata)." >&2
  echo "  Prefer --playwright-headless where possible. See docs/threat-model.md G3." >&2

  PLAYWRIGHT_COMPOSE="$(mktemp_yml)"
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
  MCP_CONFIG_WRITTEN="$MCP_CONFIG"
  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"
  echo "Playwright MCP (headless): config written — Chromium runs inside the container"

  PLAYWRIGHT_HEADLESS_COMPOSE="$(mktemp_yml)"
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

# ── --mcp: attach external HTTP MCP server(s) ────────────────────────────────
# Merges http MCP servers into the project .mcp.json (which mounts to /app and is read by
# the agent as project-scoped MCP config). On bridge networking it adds a host-gateway route
# so a server on the host is reachable at host.docker.internal — the same mechanism the
# litellm sidecar uses to reach host Ollama. The Bearer key, if given, is injected via env
# (TRIGON_MCP_KEY) and referenced by ${TRIGON_MCP_KEY} expansion in the header, so the secret
# never lands in the file. Coexists with --playwright/--playwright-headless: the .mcp.json
# merge preserves the Playwright server, and we adapt the networking (see MCP_HOST_NET below).
if [[ ${#MCP_SERVERS[@]} -gt 0 ]]; then
  if [[ $AIR_GAP -eq 1 ]]; then
    echo "Error: --mcp cannot be combined with --air-gap (host access is blocked)." >&2
    exit 1
  fi

  # --playwright switches the container to network_mode: host (incompatible with extra_hosts).
  # In that mode the host is reachable directly as 127.0.0.1, so skip the host-gateway route
  # and the URL should use 127.0.0.1 (not host.docker.internal). --playwright-headless and
  # plain --mcp stay on bridge networking, where extra_hosts is both needed and compatible.
  MCP_HOST_NET=0
  [[ $PLAYWRIGHT -eq 1 ]] && MCP_HOST_NET=1

  MCP_CONFIG="${PROJECT_ROOT}/.mcp.json"
  # Back up the user's original .mcp.json only if no earlier flag (e.g. --playwright) already
  # did — otherwise we'd clobber that backup with a generated config and lose the original.
  if [[ -z "$MCP_CONFIG_WRITTEN" && -f "$MCP_CONFIG" ]]; then
    cp "$MCP_CONFIG" "${MCP_CONFIG}.backup"
  fi

  # Merge the --mcp servers into .mcp.json (see lib/merge_mcp.py).
  python3 "${LIB_DIR}/merge_mcp.py" "$MCP_CONFIG" "$MCP_KEY" "${MCP_SERVERS[@]}"

  MCP_CONFIG_WRITTEN="$MCP_CONFIG"
  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"

  [[ -n "$MCP_KEY" ]] && EXTRA_ARGS+=(-e "TRIGON_MCP_KEY=${MCP_KEY}")

  if [[ $MCP_HOST_NET -eq 0 ]]; then
    MCP_COMPOSE="$(mktemp_yml)"
    TEMP_FILES+=("$MCP_COMPOSE")
    cat > "$MCP_COMPOSE" <<COMPOSE_EOF
services:
  ${SERVICE_NAME}:
    extra_hosts:
      - "host.docker.internal:host-gateway"
COMPOSE_EOF
    COMPOSE_FILES+=("-f" "$MCP_COMPOSE")
  fi

  if [[ $MCP_HOST_NET -eq 1 ]]; then
    echo "MCP: attached ${#MCP_SERVERS[@]} HTTP server(s) — host networking (--playwright); reach the host as 127.0.0.1"
  else
    echo "MCP: attached ${#MCP_SERVERS[@]} HTTP server(s) — host reachable at host.docker.internal"
  fi
  for spec in "${MCP_SERVERS[@]}"; do echo "  - ${spec%%=*} → ${spec#*=}"; done
  [[ -n "$MCP_KEY" ]] && echo "  auth: Authorization: Bearer <key from --mcp-key> (via \$TRIGON_MCP_KEY)"
  if [[ $MCP_HOST_NET -eq 1 ]]; then
    for spec in "${MCP_SERVERS[@]}"; do
      case "${spec#*=}" in
        *host.docker.internal*)
          echo "  WARN: host networking is active — use 127.0.0.1 in the URL, not host.docker.internal" >&2 ;;
      esac
    done
  fi
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

  AIR_GAP_COMPOSE="$(mktemp_yml)"
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

# ── Auth conflict guard (claude-code only) ────────────────────────────────────
# litellm-proxy always injects a dummy ANTHROPIC_API_KEY; a pre-existing
# claude.ai OAuth session in the settings dir will conflict with it.
if [[ "$AGENT" == "claude-code" ]]; then
  _will_inject_key=0
  [[ "$PROVIDER_TYPE" == "litellm-proxy" ]] && _will_inject_key=1
  [[ -n "${API_KEY_VALUE:-}" ]] && _will_inject_key=1
  if [[ $_will_inject_key -eq 1 ]] && [[ -f "${CLAUDE_SETTINGS_DIR}/.claude.json" ]]; then
    echo "Warning: '${NAME}' settings dir has an existing claude.ai session." >&2
    echo "  Injecting an API key alongside an OAuth token causes an auth conflict in Claude Code." >&2
    echo "  Use --name <new-name> to start with a clean settings dir." >&2
  fi
fi

# ── Cloud metadata guard (threat model G3) ────────────────────────────────────
# Host networking (--playwright) shares the host network namespace, so on a
# cloud VM the instance metadata service — and with it instance credentials —
# is one HTTP request away from the agent. We can't firewall a host-netns
# container from here without root, so instead: probe, and refuse to launch if
# metadata is reachable, unless --allow-metadata. Runs after all other guards.
# TRIGON_METADATA_PROBE=reachable|unreachable skips the probe (used by tests,
# or for hosts where the probe is slow).
if [[ $PLAYWRIGHT -eq 1 && $ALLOW_METADATA -eq 0 ]]; then
  META_STATE="${TRIGON_METADATA_PROBE:-auto}"
  if [[ "$META_STATE" == "auto" ]]; then
    META_STATE="unreachable"
    if command -v curl >/dev/null 2>&1; then
      if curl -s -m 1 -o /dev/null "http://169.254.169.254/"; then META_STATE="reachable"; fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -T 1 -t 1 -O /dev/null "http://169.254.169.254/"; then META_STATE="reachable"; fi
    fi
  fi
  if [[ "$META_STATE" == "reachable" ]]; then
    echo "Error: the cloud metadata service (169.254.169.254) is reachable from this" >&2
    echo "  host, and --playwright would share the host network with the agent —" >&2
    echo "  instance credentials would be one HTTP request away (threat-model G3)." >&2
    echo "  Prefer --playwright-headless (bridge networking), or block the metadata IP" >&2
    echo "  in the host firewall, or pass --allow-metadata to proceed anyway." >&2
    exit 1
  fi
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
echo "Compose: ${COMPOSE_FILES[*]}"

# ── Docker Compose detection ──────────────────────────────────────────────────
# Done here (just before launch) so all argument/provider validation above can
# run without Docker present — which is what lets the test suite exercise it.
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
elif [[ $DRY_RUN -eq 1 ]]; then
  # Dry-run is a config preview; show the intended command even without Docker.
  COMPOSE_CMD=(docker compose)
  echo "Note: Docker Compose not found — dry-run shows the intended command anyway." >&2
else
  echo "Error: Docker Compose not found." >&2; exit 1
fi

# ── Launch ────────────────────────────────────────────────────────────────────
# run_compose runs the assembled command — or, under --dry-run, prints it
# (shell-quoted) and exits before any container starts.
run_compose() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] would run:'
    printf ' %q' "$@"
    printf '\n'
    exit 0
  fi
  "$@"
}

if [[ "$AGENT" == "opencode" ]]; then
  # OpenCode: wrapper.sh handles pipeline/interactive mode via PROMPT_FILE env var.
  # We never override the CMD — the wrapper always runs and configures the provider.
  if [[ -n "$PROMPT_FILE" ]]; then
    EXTRA_ARGS+=(-e "PROMPT_FILE=/prompt/input.md")
    echo "Prompt file: $PROMPT_FILE (pipeline mode)"
  fi
  [[ $YOLO -eq 1 ]] && echo "Warning: --yolo has no effect for opencode (no equivalent flag)" >&2
  [[ -n "$MAX_BUDGET_USD" ]] && echo "Warning: --max-budget has no effect for opencode" >&2
  run_compose "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
    "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME"

elif [[ -n "$PROMPT_FILE" ]]; then
  CLAUDE_ARGS=(-p "$(cat "$PROMPT_FILE")" --no-session-persistence)
  [[ $YOLO -eq 1 ]] && CLAUDE_ARGS+=(--dangerously-skip-permissions)
  [[ -n "$MAX_BUDGET_USD" ]] && CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
  run_compose "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
    "${EXTRA_ARGS[@]}" "$SERVICE_NAME" claude "${CLAUDE_ARGS[@]}"

else
  if [[ $YOLO -eq 1 ]]; then
    echo "YOLO: passing --dangerously-skip-permissions to claude"
    run_compose "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
      "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME" claude --dangerously-skip-permissions
  else
    run_compose "${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" run --rm --name "$NAME" \
      "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME"
  fi
fi
