# Agents

The `--agent` flag selects the AI coding agent that runs inside the container.
The agent is the interactive layer: it receives user input (or a prompt file),
calls tools, edits files, and produces output. The provider is separate — it
is the LLM backend the agent queries.

---

## Supported agents

### `claude-code` (default)

The Anthropic Claude Code CLI (`@anthropic-ai/claude-code`).

**Strengths:**
- Deep tool-use loop (bash, read, edit, write, grep)
- CLAUDE.md project context system
- MCP (Model Context Protocol) server support
- Session persistence and compaction
- Well-documented, actively maintained
- Familiar if you already use Claude Code

**Limitations:**
- Anthropic SDK under the hood — provider switching requires compatible endpoints
- Interactive TUI is Anthropic-specific
- Closed source

**Container image:** `trigon-claude-code`  
**Entrypoint:** `wrapper.sh` → injects mode context → `claude [args]`  
**Provider support:** all tiers via `ANTHROPIC_BASE_URL` / LiteLLM sidecar

```bash
./trigon-up.sh ~/project                          # default
./trigon-up.sh ~/project --agent claude-code      # explicit
./trigon-up.sh ~/project --agent claude-code --provider deepseek
```

**CLAUDE.md integration:** works as normal. Place a `CLAUDE.md` in your project
root and Claude Code will pick it up automatically.

**MCP servers:** configure via `.mcp.json` in the project root, or use the
`--playwright` flag for browser automation.

---

### `opencode`

OpenCode — an open-source AI coding agent with native multi-provider support.

**Strengths:**
- Natively multi-provider (does not depend on `ANTHROPIC_BASE_URL` trick)
- Strong TUI, praised by users (HN thread #48002136)
- Open source, TypeScript
- Built-in agent specialisation: `build` agent (full access), `plan` agent
  (read-only analysis), `general` subagent (complex search)
- Docker-native: official image at `ghcr.io/anomalyco/opencode`

**Limitations:**
- Younger project, fewer integrations than Claude Code
- No CLAUDE.md equivalent (uses its own config format)
- MCP support: partial / in progress (check upstream)
- Provider config format differs from Trigon's `--provider` flag (adapter
  needed — see below)

**Container image:** `trigon-opencode`  
**Entrypoint:** `wrapper.sh` → generates `opencode.config.json` → `opencode [args]`  
**Provider support:** via OpenCode's own config system

```bash
./trigon-up.sh ~/project --agent opencode
./trigon-up.sh ~/project --agent opencode --provider anthropic
./trigon-up.sh ~/project --agent opencode --provider openrouter/google/gemini-2.5-pro
```

**Provider adapter:** because OpenCode has its own provider config, Trigon's
`wrapper.sh` generates an `opencode.config.json` at container startup from the
`--provider` argument. The mapping lives in `agents/opencode/provider-map.yml`.

---

## Comparison

| Feature | claude-code | opencode |
|---------|------------|---------|
| Interactive TUI | yes | yes (praised) |
| Provider agnosticism | via env vars / proxy | native |
| CLAUDE.md | yes | no (own format) |
| MCP servers | yes (mature) | partial |
| Session persistence | yes | yes |
| Open source | no | yes |
| Pipeline / `--no-tui` mode | yes (`-p` flag) | yes |
| Actively maintained | yes | yes |
| Docker image available | via Trigon build | ghcr.io/anomalyco/opencode |

---

## Architecture: how agents are wired

Each agent lives in `agents/<name>/`:

```
agents/
  claude-code/
    Dockerfile          # base image + claude-code install + mode packages
    wrapper.sh          # mode context injection, then exec claude
  opencode/
    Dockerfile          # opencode image + mode packages
    wrapper.sh          # generates opencode.config.json, then exec opencode
    provider-map.yml    # maps Trigon provider names → opencode config
```

The compose service for each agent is defined in `compose/base.yml` as a
separate service with its own image reference. `trigon-up.sh` selects the
service based on `--agent`.

---

## Pipeline mode per agent

Both agents support non-interactive pipeline mode:

**claude-code:**
```bash
./trigon-up.sh ~/project --agent claude-code \
  --prompt-file ./plan.md --provider deepseek
```
Internally: `claude -p "$(cat /prompt/input.md)" --no-session-persistence`

**opencode:**
```bash
./trigon-up.sh ~/project --agent opencode \
  --prompt-file ./plan.md --provider anthropic
```
Internally: `opencode --no-tui --message "$(cat /prompt/input.md)"`
(exact flag TBC pending OpenCode CLI documentation review)

---

## Adding a new agent

1. Create `agents/myagent/Dockerfile`
2. Create `agents/myagent/wrapper.sh` — must:
   - Accept mode context injection
   - Accept `PROMPT_FILE` env var for pipeline mode
   - Accept provider configuration (env vars or generated config)
3. Add a service fragment to `compose/base.yml`
4. If the agent has its own provider format, add `agents/myagent/provider-map.yml`
5. Update `trigon-up.sh` to handle `--agent myagent`
6. Document in this file

Candidate agents for future support:
- **Aider** (`aider-chat/aider`) — git-native, strong diff UX
- **Goose** (Block) — open-source, extensible
- **Continue** — VS Code / IDE native
- Custom script-based agents (just a Dockerfile + wrapper)
