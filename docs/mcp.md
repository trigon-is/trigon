# External MCP servers (`--mcp`)

`--mcp NAME=URL` attaches an external **HTTP** [MCP](https://modelcontextprotocol.io)
server to the agent for the duration of a run. It is repeatable, coexists with
the Playwright flags, and cleans up after itself.

```bash
./trigon-up.sh ~/my-project --mcp palladium-gm=http://host.docker.internal:8000/mcp/
```

## What it does

For each `NAME=URL` spec, `trigon-up.sh` merges an entry into the project's
`.mcp.json` (the file the agent reads as project-scoped MCP config):

```json
{
  "mcpServers": {
    "palladium-gm": { "type": "http", "url": "http://host.docker.internal:8000/mcp/" }
  }
}
```

The merge is performed by [`lib/merge_mcp.py`](../lib/merge_mcp.py). It is
**additive** — any servers already in `.mcp.json` (including one written by
`--playwright`) are preserved. The original file is backed up and **restored on
exit**, so your working tree is left untouched.

## Reaching a server on the host

How the container reaches a server running on your host machine depends on the
networking mode, which the Playwright flags change:

| Situation | Networking | Use this host in the URL |
|-----------|------------|--------------------------|
| Plain `--mcp` | bridge | `host.docker.internal` |
| `--mcp` + `--playwright-headless` | bridge | `host.docker.internal` |
| `--mcp` + `--playwright` | host | `127.0.0.1` |

On bridge networking, Trigon adds a `host.docker.internal:host-gateway` route
(the same mechanism the LiteLLM sidecar uses to reach a host Ollama). Under
`--playwright`, the container shares the host network stack, so the host is
simply `127.0.0.1` and `host.docker.internal` will **not** resolve —
`trigon-up.sh` warns if it sees `host.docker.internal` in a URL in that mode.

## Trailing slash matters

Servers mounted under a sub-path by Starlette/FastMCP (e.g. mounted at `/mcp`)
require a **trailing slash** on the URL:

```
✅ http://host.docker.internal:8000/mcp/
❌ http://host.docker.internal:8000/mcp
```

Without it the request can fall through to the parent app and silently fail to
reach the MCP endpoint.

## Authentication (`--mcp-key`)

`--mcp-key VALUE` adds an `Authorization: Bearer VALUE` header to every `--mcp`
server. The secret is **not** written into `.mcp.json`; the file only contains a
`${TRIGON_MCP_KEY}` reference, and the real value is passed into the container
via the `TRIGON_MCP_KEY` environment variable:

```bash
./trigon-up.sh ~/my-project \
  --mcp palladium-gm=http://host.docker.internal:8000/mcp/ \
  --mcp-key "$(cat ~/.palladium_token)"
```

## Constraints

- **Incompatible with `--air-gap`** — air-gap blocks host access, which is
  exactly what `--mcp` needs. `trigon-up.sh` errors if both are given.
- Currently only `type: http` MCP servers are supported via this flag.
