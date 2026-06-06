#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT="claude-code"
MODE="dev"
PUSH=0

usage() {
  echo "Usage: $0 [--agent claude-code] [--mode dev|security] [--push]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent=*)  AGENT="${1#--agent=}" ;;
    --agent)    shift; AGENT="${1:-}" ;;
    --mode=*)   MODE="${1#--mode=}" ;;
    --mode)     shift; MODE="${1:-}" ;;
    --push)     PUSH=1 ;;
    --help|-h)  usage ;;
    *)          echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done

case "$MODE" in
  dev|security) ;;
  *) echo "Error: unknown mode '${MODE}'. Valid: dev, security" >&2; exit 1 ;;
esac

case "$AGENT" in
  claude-code) ;;
  *) echo "Error: unknown agent '${AGENT}'. Valid: claude-code" >&2; exit 1 ;;
esac

IMAGE_TAG="${AGENT}-${MODE}:latest"
DOCKERFILE="${SCRIPT_DIR}/agents/${AGENT}/Dockerfile"

echo "Building: ${IMAGE_TAG}"
echo "Agent: ${AGENT} | Mode: ${MODE}"

docker build \
  --build-arg MODE="${MODE}" \
  -t "${IMAGE_TAG}" \
  -f "${DOCKERFILE}" \
  "${SCRIPT_DIR}"

echo "Done: ${IMAGE_TAG}"

if [[ $PUSH -eq 1 ]]; then
  docker push "${IMAGE_TAG}"
fi
