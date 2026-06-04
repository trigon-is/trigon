#!/usr/bin/env bash
set -euo pipefail

# Usage: ./claude-up.sh [PATH_TO_PROJECT] ... [--security] [--name NAME] [--yolo] [--root] [--playwright] [--api] [--prompt-file PATH]
# If no PATH_TO_PROJECT specified, defaults to the current directory.
# Supports up to 5 project directories.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Collect project paths (all non-flag arguments at the beginning)
PROJECT_PATHS=()
FLAGS=()

for arg in "$@"; do
  case "$arg" in
    --*)
      FLAGS+=("$arg")
      ;;
    *)
      if [[ ${#FLAGS[@]} -eq 0 ]]; then
        PROJECT_PATHS+=("$arg")
      else
        FLAGS+=("$arg")
      fi
      ;;
  esac
done

# If no project paths specified, use current directory
if [[ ${#PROJECT_PATHS[@]} -eq 0 ]]; then
  PROJECT_PATHS=("$(pwd)")
fi

# Limit to 5 project paths
if [[ ${#PROJECT_PATHS[@]} -gt 5 ]]; then
  echo "Error: Maximum 5 project directories supported" >&2
  exit 1
fi

# Resolve all paths to absolute paths and export
for i in "${!PROJECT_PATHS[@]}"; do
  path="${PROJECT_PATHS[$i]}"
  if [[ ! -d "$path" ]]; then
    echo "Error: Directory does not exist: $path" >&2
    exit 1
  fi
  abs_path="$(cd "$path" && pwd)"
  PROJECT_PATHS[$i]="$abs_path"

  if [[ $i -eq 0 ]]; then
    export PROJECT_ROOT="$abs_path"  # Maintain backwards compatibility
  fi
  export "PROJECT_ROOT_$((i+1))"="$abs_path"
done

# Default settings
NAME="claude-code"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yml"
SERVICE_NAME="claude"
SECURITY_MODE=0
PROMPT_FILE=""

# Parse flags — while loop supports VALUE-form: --name VALUE, --prompt-file VALUE
i=0
while [[ $i -lt ${#FLAGS[@]} ]]; do
  arg="${FLAGS[$i]}"
  case "$arg" in
    --security)
      SECURITY_MODE=1
      COMPOSE_FILE="${SCRIPT_DIR}/compose.security.yml"
      SERVICE_NAME="claude-sec"
      NAME="claude-code-sec"
      ;;
    --name=*)
      NAME="${arg#--name=}"
      ;;
    --name)
      if [[ $((i+1)) -lt ${#FLAGS[@]} ]]; then
        NAME="${FLAGS[$((i+1))]}"
        i=$((i+1))
      else
        echo "Error: --name requires a value" >&2
        exit 1
      fi
      ;;
    --prompt-file=*)
      PROMPT_FILE="${arg#--prompt-file=}"
      ;;
    --prompt-file)
      if [[ $((i+1)) -lt ${#FLAGS[@]} ]]; then
        PROMPT_FILE="${FLAGS[$((i+1))]}"
        i=$((i+1))
      else
        echo "Error: --prompt-file requires a path argument" >&2
        exit 1
      fi
      ;;
  esac
  i=$((i+1))
done

# Pick Compose (plugin or legacy)
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "Docker Compose not found." >&2
  exit 1
fi

YOLO=0
ROOT_MODE=0
PLAYWRIGHT=0
USE_API_KEY=0
for arg in "${FLAGS[@]}"; do
  [[ "$arg" == "--yolo" ]] && YOLO=1
  [[ "$arg" == "--root" ]] && ROOT_MODE=1
  [[ "$arg" == "--playwright" ]] && PLAYWRIGHT=1
  [[ "$arg" == "--playwrite" ]] && PLAYWRIGHT=1  # Support common misspelling
  [[ "$arg" == "--api" ]] && USE_API_KEY=1
done

# Security-specific environment setup
if [[ $SECURITY_MODE -eq 1 ]]; then
  SECURITY_RESULTS_DIR="${SECURITY_RESULTS_DIR:-$PWD/security-results}"
  WORDLISTS_DIR="${WORDLISTS_DIR:-$PWD/wordlists}"
  mkdir -p "$SECURITY_RESULTS_DIR" "$WORDLISTS_DIR"
  export SECURITY_RESULTS_DIR WORDLISTS_DIR
  echo "Security mode enabled"
  echo "Results will be saved to: $SECURITY_RESULTS_DIR"
fi

# --api flag: load key from ~/.anthropic_api_key and pass into container.
# Without this flag, sessions use OAuth (Pro quota) as normal.
if [[ $USE_API_KEY -eq 1 ]]; then
  KEY_FILE="${HOME}/.anthropic_api_key"
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    if [[ ! -f "$KEY_FILE" ]]; then
      echo "Error: --api flag set but no key found. Set ANTHROPIC_API_KEY or create ~/.anthropic_api_key" >&2
      exit 1
    fi
    ANTHROPIC_API_KEY="$(cat "$KEY_FILE")"
  fi
  export ANTHROPIC_API_KEY
  echo "API key loaded — this session will use Anthropic API billing, not Pro quota."
fi

# --prompt-file: resolve to absolute path and validate
if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
  fi
  echo "Prompt file: $PROMPT_FILE (non-interactive mode)"
fi

[[ $ROOT_MODE -eq 1 ]] \
  && { export LOCAL_UID=0; export LOCAL_GID=0; } \
  || { export LOCAL_UID="$(id -u)"; export LOCAL_GID="$(id -g)"; }

# Where to persist settings on your host:
CLAUDE_SETTINGS_DIR="${CLAUDE_SETTINGS_DIR:-$HOME/.claude-settings${NAME:+-$NAME}}"
mkdir -p "$CLAUDE_SETTINGS_DIR"
export CLAUDE_SETTINGS_DIR

# Configure Playwright MCP if flag is set.
# The network switch is applied to whichever compose file is already selected —
# compose.yml in normal mode, compose.security.yml when --security is also set.
if [[ $PLAYWRIGHT -eq 1 ]]; then
  MCP_CONFIG="${PROJECT_ROOT}/.mcp.json"
  if [[ -f "$MCP_CONFIG" ]]; then
    cp "$MCP_CONFIG" "${MCP_CONFIG}.backup"
  fi
  cp "${SCRIPT_DIR}/mcp-config-template.json" "$MCP_CONFIG"
  echo "Created Playwright MCP config (host Chrome): $MCP_CONFIG"

  mkdir -p "$CLAUDE_SETTINGS_DIR/config"
  cp "$MCP_CONFIG" "$CLAUDE_SETTINGS_DIR/config/mcp.json"

  TEMP_COMPOSE=$(mktemp)
  sed 's/network_mode: "bridge"/network_mode: "host"/' "$COMPOSE_FILE" > "$TEMP_COMPOSE"
  COMPOSE_FILE="$TEMP_COMPOSE"

  export PLAYWRIGHT_ENABLED=1
else
  export PLAYWRIGHT_ENABLED=0
fi

# Display mounted directories
echo "Mounting project directories:"
for i in "${!PROJECT_PATHS[@]}"; do
  if [[ $i -eq 0 ]]; then
    echo "  ${PROJECT_PATHS[$i]} -> /app"
  else
    echo "  ${PROJECT_PATHS[$i]} -> /app_$((i+1))"
  fi
done
echo "Using compose file: $COMPOSE_FILE"
echo "Service name: $SERVICE_NAME"
if [[ $PLAYWRIGHT -eq 1 ]]; then
  echo "Playwright MCP enabled - connecting to host Chrome on localhost:9222"
  echo "Make sure Chrome is running with: chrome --remote-debugging-port=9222"
fi

# Build extra args for docker compose run.
# API key is only injected when --api is explicitly requested — it never reaches
# the container in a normal Pro session.
EXTRA_ARGS=()
if [[ $USE_API_KEY -eq 1 ]]; then
  EXTRA_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi
if [[ -n "$PROMPT_FILE" ]]; then
  EXTRA_ARGS+=(-v "${PROMPT_FILE}:/prompt/input.md:ro")
fi

if [[ -n "$PROMPT_FILE" ]]; then
  # Non-interactive pipeline mode: pass prompt content and exit
  CLAUDE_ARGS=(-p "$(cat "$PROMPT_FILE")" --no-session-persistence)
  [[ $YOLO -eq 1 ]] && CLAUDE_ARGS+=(--dangerously-skip-permissions)
  [[ -n "${MAX_BUDGET_USD:-}" ]] && CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
  exec $COMPOSE -f "$COMPOSE_FILE" run --rm --name "$NAME" "${EXTRA_ARGS[@]}" \
    "$SERVICE_NAME" claude "${CLAUDE_ARGS[@]}"
else
  # Normal interactive mode
  if [[ $YOLO -eq 1 ]]; then
    echo "YOLO: passing --dangerously-skip-permissions to claude CLI"
    exec $COMPOSE -f "$COMPOSE_FILE" run --rm --name "$NAME" "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME" claude --dangerously-skip-permissions
  else
    exec $COMPOSE -f "$COMPOSE_FILE" run --rm --name "$NAME" "${EXTRA_ARGS[@]}" -it "$SERVICE_NAME"
  fi
fi
