# Reverse Engineering — Code Structure (audit-relevant)

## Build system
- **Launcher**: `trigon-up.sh` (Bash) — flag parsing, provider resolution,
  compose assembly, cleanup trap.
- **Images**: `build.sh` + `agents/*/Dockerfile` (multi-stage). Not on the
  `--audit` critical path except that the proxy image is pulled at runtime, not
  baked.
- **Helpers**: `lib/parse_provider.py`, `lib/merge_mcp.py` — embedded-Python
  helpers invoked by the launcher. A future audit-summary generator could follow
  the same pattern (a `lib/*.py` called at session end).

## The compose-fragment machinery (the extension point)

Pattern, repeated per feature in `trigon-up.sh`:

```
mktemp_yml()            # portable temp .yml (BSD/GNU)           :9-14
COMPOSE_FILES=(...)     # array of -f args, starts with base.yml :331
TEMP_FILES+=(...)       # tracked for cleanup                    per fragment
cleanup() { rm -f "${TEMP_FILES[@]}"; ... }                      :351
trap cleanup EXIT INT TERM                                       :361
```

Each feature: create a temp yml, `cat` a compose fragment into it, append
`-f "$FRAG"` to `COMPOSE_FILES`, register it in `TEMP_FILES`.

### Fragments today (models for the audit fragment)
- **litellm sidecar** — `:419-446` — a full sidecar service with image,
  `extra_hosts`, config mount. Closest template for a proxy sidecar.
- **playwright (host net)** — `:540-547` — `network_mode: host`.
- **playwright-headless** — `:568-580` — `ipc`, `SYS_PTRACE`, browsers path.
- **mcp** — `:622-630` — extra_hosts wiring.
- **air-gap** — `:667-701` — `internal: true` network + per-service `networks:`
  reassignment. **This is the key template**: it shows how to move the agent off
  the default network and dual-home a sidecar.

## Relevant flags & guards inventory
- `--audit` — **does not exist yet** (this feature).
- `--air-gap` (`:203`, `:650`), `--allow-metadata` (`:205`, `:719`),
  `--playwright` / `--playwright-headless` (`:192-193`).
- Incompatibility guards to mirror: playwright×litellm (`:388`),
  air-gap×playwright (`:652`), air-gap×direct-provider (`:657`),
  mcp×air-gap (`:594`).

## Env injection path
- `EXTRA_ARGS+=(-e "KEY=VALUE")` appends container env (e.g.
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` at `:505-509`). An audit proxy would
  inject `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (and possibly a CA cert path) the
  same way.

## Test surface (where audit tests will live)
- `tests/cli/*.bats` — `hardening.bats`, `guards.bats`, `dryrun.bats`. A new
  `tests/cli/audit.bats` fits the existing convention; `--dry-run` already lets
  tests assert on generated compose without launching Docker.
- `tests/test_*.py` — host-side unittest for `lib/` helpers; an audit-summary
  helper would get a `tests/test_audit_summary.py`.
