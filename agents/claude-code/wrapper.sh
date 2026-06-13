#!/bin/bash
set -euo pipefail

TRIGON_MODE="${TRIGON_MODE:-dev}"

# Inject mode context into ~/.claude/CLAUDE.md (Claude Code reads this automatically)
CONTEXT_FILE="/modes/${TRIGON_MODE}/context.md"
if [[ -f "$CONTEXT_FILE" && -s "$CONTEXT_FILE" ]]; then
    mkdir -p /settings/.claude
    cp "$CONTEXT_FILE" /settings/.claude/CLAUDE.md
    echo "Mode context loaded (${TRIGON_MODE})"
fi

exec claude "$@"
