#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT="claude-code"
MODE="dev"
PUSH=0
CLAUDE_VERSION="2.1.144"
OPENCODE_VERSION="latest"

usage() {
  echo "Usage: $0 [--agent claude-code|opencode] [--mode dev|security] [--claude-version VERSION] [--opencode-version VERSION] [--push]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent=*)          AGENT="${1#--agent=}" ;;
    --agent)            shift; AGENT="${1:-}" ;;
    --mode=*)           MODE="${1#--mode=}" ;;
    --mode)             shift; MODE="${1:-}" ;;
    --claude-version=*)   CLAUDE_VERSION="${1#--claude-version=}" ;;
    --claude-version)     shift; CLAUDE_VERSION="${1:-}" ;;
    --opencode-version=*) OPENCODE_VERSION="${1#--opencode-version=}" ;;
    --opencode-version)   shift; OPENCODE_VERSION="${1:-}" ;;
    --push)             PUSH=1 ;;
    --help|-h)          usage ;;
    *)                  echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done

case "$MODE" in
  dev|security) ;;
  *) echo "Error: unknown mode '${MODE}'. Valid: dev, security" >&2; exit 1 ;;
esac

case "$AGENT" in
  claude-code) ;;
  opencode)
    if [[ "$MODE" != "dev" ]]; then
      echo "Error: opencode agent currently only supports --mode dev" >&2; exit 1
    fi
    ;;
  *) echo "Error: unknown agent '${AGENT}'. Valid: claude-code, opencode" >&2; exit 1 ;;
esac

IMAGE_TAG="${AGENT}-${MODE}:latest"
DOCKERFILE="${SCRIPT_DIR}/agents/${AGENT}/Dockerfile"

echo "Building: ${IMAGE_TAG}"

if [[ "$AGENT" == "opencode" ]]; then
  echo "Agent: ${AGENT} | Mode: ${MODE} | OpenCode: ${OPENCODE_VERSION}"
  docker build \
    --build-arg MODE="${MODE}" \
    --build-arg OPENCODE_VERSION="${OPENCODE_VERSION}" \
    -t "${IMAGE_TAG}" \
    -f "${DOCKERFILE}" \
    "${SCRIPT_DIR}"
else
  echo "Agent: ${AGENT} | Mode: ${MODE} | Claude Code: ${CLAUDE_VERSION}"
  docker build \
    --build-arg MODE="${MODE}" \
    --build-arg CLAUDE_VERSION="${CLAUDE_VERSION}" \
    -t "${IMAGE_TAG}" \
    -f "${DOCKERFILE}" \
    "${SCRIPT_DIR}"
fi

echo "Done: ${IMAGE_TAG}"

if [[ $PUSH -eq 1 ]]; then
  docker push "${IMAGE_TAG}"
fi
