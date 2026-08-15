# `--audit` — Network Audit Log: Application Design

> **Status:** Application Design (AI-DLC M7 cycle). Consolidates component,
> service, NFR, and infrastructure design for the `--audit` feature. Source of
> record for Construction. Requirements: `docs/audit/inception/requirements/requirements.md`.
> Reasoning primer: `docs/audit-concepts.md`.

## 1. Summary

`--audit` makes a Trigon container session produce an **unbypassable, complete
record of where the agent's traffic went**, written outside the agent's reach.
It is **opt-in** (default off) and changes nothing for runs that don't request it.

Two orthogonal guarantees (see `docs/audit-concepts.md`):

- **Completeness (hard).** The agent is placed on an `internal` Docker network
  with no route to the internet; a **transparent audit gateway** sidecar
  (mitmproxy, `NET_ADMIN` scoped to the sidecar) is its only path out and logs
  every destination — even for a hostile agent that ignores proxy settings.
- **Depth (soft, opt-in).** `--audit-decrypt` adds TLS interception for flows
  whose client trusts the session CA (the *honest* flows), capturing method/path/
  status. Flows that pin or reject the CA are **passed through opaque but still
  logged by destination** — so depth degrades without ever breaking completeness.

Default depth is **destination-only** (SNI/CONNECT host + byte counts, no
decryption) — a compliance artifact with minimal PII surface.

## 2. Design decisions (locked)

| # | Decision | Rationale / NFR |
|---|----------|-----------------|
| D1 | **Transparent gateway** (A): agent on `internal` net, mitmproxy sidecar dual-homed with `NET_ADMIN`, iptables REDIRECT, is the agent's route out. Logs all destinations incl. hostile. **Fallback (B):** internal-net + explicit `HTTP(S)_PROXY` (drop-by-default) if A is infeasible in Compose. | FR-3, NFR-3, NFR-9 |
| D2 | **Decrypt-refusal = pass-through-SNI** (default). Pinned/hostile flows tunneled opaque, logged by destination. `--audit-decrypt-fail-closed` drops them instead. | NFR-10 |
| D3 | **Log lives in a sidecar-only bind mount** (`audit-log/` mounted into the gateway, not the agent). Live during session, agent can't tamper. | NFR-4 |
| D4 | **Purpose-built gateway image** `trigon-audit-gw` = mitmproxy + iptables (+ procps), built by `./build.sh --audit-gateway`. The stock mitmproxy image lacks `iptables`, which the transparent REDIRECT needs (would exit 127). Base `mitmproxy/mitmproxy` pinned by version (digest before release). Serves both destination-only and decrypt paths. | NFR-6, SECURITY-10/13 |
| D5 | **`--audit` + `--playwright-headless` allowed** — headless Chromium stays namespaced, routes through the gateway. `--audit` + `--playwright` (host net) **refused**. | FR-7 |
| D6 | **Flags:** `--audit`, `--audit-decrypt`, `--audit-allow-degraded`, `--audit-decrypt-fail-closed`. | FR-1, NFR-5 |

## 3. Topology

### 3.1 Default (destination-only)

```
                internal net (no gateway → no direct egress)
   ┌───────────────────────────────────────────────┐
   │  [ agent: trigon ]                             │
   │     cap_drop: ALL, no-new-privileges           │
   │     default route ─────────────► audit-gw      │
   └───────────────────────────────────┬───────────┘
                                        │ dual-homed
                                        ▼
                          [ audit-gw: mitmproxy ]
                            cap_add: NET_ADMIN (sidecar only)
                            iptables REDIRECT :80→8080 :443→8080
                            transparent mode, SNI/CONNECT logging
                                        │ default (bridge) net
                                        ▼
                                     NAT → internet
                                        │
                            writes ─────┴──────► audit-log/  (sidecar-only mount)
```

- Agent has **no** route to the internet except through `audit-gw` (internal net
  removes the default gateway; the sidecar re-supplies it).
- Non-forwarded / non-routable traffic simply cannot leave → nothing escapes
  unlogged (completeness by construction, NFR-3).

### 3.2 With litellm sidecar (tier-2 providers)

```
[ agent ] ──► [ audit-gw ] ──► internet (provider API direct)
     └───────► [ litellm ]  ──► provider / host Ollama
```

- **Ordering:** the audit gateway wraps the agent's *external* egress; the litellm
  hop is agent→litellm on the internal net (observed as an internal destination),
  and litellm→provider is litellm's own egress. To keep the completeness claim
  honest, **litellm is also placed behind the gateway** (litellm dual-homed:
  internal + gateway-routed), so provider calls are logged too. If that proves
  awkward, the documented degradation is: litellm→provider is *not* agent traffic
  and may be logged at the litellm boundary instead (noted in the summary).
  Resolve concretely during Functional Design against a live stack.

### 3.3 `--air-gap --audit`

- `internal: true` with **no** dual-homed gateway leg → zero egress. The log is
  an empty/near-empty JSONL and the summary asserts **"0 outbound requests"** as a
  positive zero-egress proof (FR-9).

## 4. Components

### C1 — Launcher flag & fragment logic (`trigon-up.sh`)
**Responsibility:** parse the four audit flags; enforce guards; generate the audit
compose fragment (temp yml via `mktemp_yml`, appended to `COMPOSE_FILES`, tracked
in `TEMP_FILES`, removed by the existing `cleanup` trap); inject env into the agent
on the decrypt path; run the summary helper at session end.

Integration points (existing code):
- Flag parse block — `trigon-up.sh:190-208` (add cases alongside `--air-gap`).
- Guard block — mirror `--air-gap` × `--playwright` refusal at `:652-655`.
- Fragment generation — model on the air-gap fragment `:667-701` (network reassign)
  + litellm fragment `:419-446` (sidecar shape).
- Env injection — `EXTRA_ARGS+=(-e ...)` as at `:502-509` (decrypt path only).
- Cleanup — `TEMP_FILES` + `cleanup()` `:349-360`; CA material also registered.

### C2 — Audit gateway sidecar (generated compose service `audit-gw`)
**Responsibility:** be the agent's sole egress path; log every connection; on the
decrypt path, MITM CA-accepting flows and pass through the rest.

- Image: `trigon-audit-gw:latest` (D4) — mitmproxy + iptables, built from
  `compose/audit/Dockerfile` via `./build.sh --audit-gateway`. Base pinned by
  version (digest before release). `trigon-up.sh` fails closed if it is absent.
- Caps: `cap_add: [NET_ADMIN]` only; inherits base `cap_drop: ALL` +
  `no-new-privileges` for everything else (NFR-9). *Verify* NET_ADMIN alone
  suffices for the iptables REDIRECT; add nothing broader.
- Entry: an addon/script that (a) sets iptables REDIRECT for :80/:443 → mitmproxy
  listener, (b) runs mitmproxy in `transparent` mode (destination-only) or with
  decryption enabled (`--audit-decrypt`), (c) writes JSONL via a mitmproxy addon.
- Networks: `internal` (agent-facing) + `default` (egress).
- Log target: `audit-log/` bind-mounted **into this service only**.

### C3 — Summary / parse helper (`lib/audit_summary.py`)
**Responsibility:** read the JSONL log, emit the human-readable session summary
(unique destinations, per-destination request counts, total bytes, first/last
timestamps, decrypted-vs-metadata-only counts, and a "0 outbound requests" line
when empty). Pure function over the log file; no Docker. Follows the existing
embedded-`lib/*.py` pattern (`parse_provider.py`, `merge_mcp.py`).

## 5. Data design — audit log

### 5.1 JSONL record (one connection/request per line)

```jsonc
{
  "v": 1,                          // schema version
  "ts": "2026-08-15T12:34:56.789Z",// ISO-8601 UTC, connection/request start
  "mode": "metadata" | "decrypted",// per-record depth
  "dst_host": "api.anthropic.com", // SNI / CONNECT host; "" if IP-literal
  "dst_ip": "203.0.113.7",         // resolved / literal peer IP
  "dst_port": 443,
  "bytes_out": 1234,               // agent→dst
  "bytes_in": 5678,                // dst→agent
  // decrypted-only, redacted per NFR-1 (never present in metadata mode):
  "method": "POST",
  "path": "/v1/messages",          // query string tokens stripped (NFR-1)
  "status": 200
}
```

- `mode` marks each record's depth so a mixed log (some flows decrypted, some
  passed through) is self-describing.
- **Never** written: request/response bodies; `Authorization` /
  `Proxy-Authorization` headers; API keys; query-string tokens (NFR-1). Path is
  recorded with the query string stripped.
- IP-literal connections: `dst_host: ""`, logged by `dst_ip` (NFR-3 caveat b).

### 5.2 Session summary (`audit-log/summary-<timestamp>.txt`)
Human-readable: total requests, unique destinations (sorted by count), total
bytes, first/last timestamp, decrypted vs metadata-only counts, and — when empty
— an explicit `0 outbound requests — zero-egress verified` line (FR-9).

### 5.3 Layout in `audit-log/`
```
audit-log/
  session-<name>-<ts>.jsonl     # the machine log (sidecar-owned)
  summary-<name>-<ts>.txt       # human summary (written by C3 at session end)
```

## 6. Interfaces — flag surface

| Flag | Effect |
|------|--------|
| `--audit` | Enable audit gateway; destination-only logging (default depth). |
| `--audit-decrypt` | Add TLS interception for CA-accepting flows; inject session CA into the agent trust store; capture method/path/status (redacted). |
| `--audit-decrypt-fail-closed` | On MITM refusal, **drop** the flow instead of pass-through-SNI (D2 strict variant). No effect without `--audit-decrypt`. |
| `--audit-allow-degraded` | Opt into **fail-open**: if the gateway can't start, launch unaudited with a loud warning (default is fail-closed, NFR-5). |

Guards:
- `--audit` + `--playwright` → **refuse** (host netns unobservable; FR-7),
  mirroring `:652-655`.
- `--audit-decrypt` / `--audit-decrypt-fail-closed` without `--audit` → error.
- `--audit` implies the agent goes on the internal net; if combined with
  `--air-gap`, no dual-homed egress leg is added (§3.3).

## 7. Service orchestration & lifecycle

1. **Assembly:** `--audit` appends the generated `audit-gw` fragment to
   `COMPOSE_FILES` and reassigns the agent to the internal net (air-gap-style).
2. **Startup (fail-closed, NFR-5):** agent `depends_on: audit-gw:
   condition: service_healthy` (mirrors the litellm healthcheck pattern
   `:439-444`). If `audit-gw` is unhealthy, compose never starts the agent →
   the session does not run unaudited. `--audit-allow-degraded` relaxes this.
3. **Runtime:** all agent egress transits `audit-gw`; each flow is appended to the
   JSONL on the sidecar-only mount.
4. **Session end:** `trigon-up.sh` invokes `lib/audit_summary.py` on the JSONL to
   write the summary; the `cleanup` trap removes generated fragments + CA material
   (NFR-7). The JSONL + summary remain in `audit-log/`.

## 8. NFR design mapping

| NFR | Design realization |
|-----|--------------------|
| NFR-1 redaction | Destination-only mode records no path/header/body by construction. Decrypt-mode addon strips `Authorization`/`Proxy-Authorization`, API keys, query tokens; never writes bodies. |
| NFR-2 cert-pinning | Decrypt path injects the CA (`NODE_EXTRA_CA_CERTS` for Claude Code/Node). Verification step in Build & Test: confirm the agent's *own* provider calls still succeed under decrypt; D2 pass-through prevents a pinned provider call from breaking the run. |
| NFR-3 completeness | Internal net removes the agent's egress; sidecar is the sole route (D1-A). All escaping traffic is logged. Documented caveats: metadata mode can't see content; IP-literals logged by IP; guarantee holds only for the gateway topology → FR-7 refuses host-net. |
| NFR-4 tamper-resistance | Log on a **sidecar-only** bind mount (D3); agent has no path to it. |
| NFR-5 fail-closed | `depends_on: service_healthy`; no agent launch if gateway unhealthy. `--audit-allow-degraded` opts into fail-open. |
| NFR-6 pinned image | mitmproxy pinned by digest (D4). |
| NFR-7 cleanup | Generated fragment, CA material, temp config in `TEMP_FILES`; removed by `cleanup` trap on EXIT/INT/TERM. |
| NFR-8 testability | `--dry-run` surfaces the fragment; `tests/cli/audit.bats` + `tests/test_audit_summary.py` (+ PBT). |
| NFR-9 least-privilege | `audit-gw` is `cap_drop: ALL` + `cap_add: [NET_ADMIN, DAC_OVERRIDE]` — NET_ADMIN for the iptables REDIRECT, DAC_OVERRIDE so root can write the log/CA into the host-owned (`mktemp`, uid-1000) bind mount (dropping ALL strips DAC_OVERRIDE, so uid-0 is otherwise blocked by ordinary perms). Both scoped to the sidecar; the agent keeps `cap_drop: ALL`. |
| NFR-10 hard vs soft | Completeness (routing) unbypassable; decryption (CA trust) cooperative. Docs/`--help` never call `--audit-decrypt` unbypassable; pass-through default keeps completeness when decrypt fails. |

## 9. Test design (for Build & Test)

- **`tests/cli/audit.bats`** (no Docker, via `--dry-run`):
  - `--audit` emits an `audit-gw` service + reassigns the agent to the internal net.
  - `audit-gw` has `cap_add: NET_ADMIN` and the agent does **not**.
  - `--audit` + `--playwright` refuses to launch.
  - `--audit-decrypt-fail-closed` / `--audit-decrypt` without `--audit` errors.
  - `--air-gap --audit` adds no external gateway leg.
  - agent `depends_on: audit-gw` healthy (fail-closed); `--audit-allow-degraded` drops it.
- **`tests/test_audit_summary.py`** (host-side unit + PBT, NFR-8/PBT-02/03/07/08/09):
  - round-trip: serialize records → parse → summary counts match (PBT).
  - malformed/partial lines are skipped without crashing (PBT robustness).
  - redaction: no `Authorization`/key/token substrings survive into any output.
  - empty log → "0 outbound requests" summary.
- **Live-container verification (parked — no Docker in dev sessions):** enforced
  routing (agent cannot reach the internet except via `audit-gw`); `--audit-decrypt`
  doesn't break Claude Code's own provider calls; `--air-gap --audit` zero-egress.

## 10. Open items carried to Construction / Functional Design

- Exact mechanism to pin the agent's default route to `audit-gw` in Compose
  without granting the agent `NET_ADMIN` (the crux of D1-A feasibility; decides
  whether the B fallback is needed).
- Concrete litellm ordering (§3.2) against a live stack.
- mitmproxy addon shape for JSONL + redaction; digest pin selection.
- Whether `--playwright-headless` egress is confirmed to transit the gateway in a
  live run (expected yes; verify).

## 11. Prior art / differentiation
VibePod (verified, see requirements §Prior Art) is the inverse: always-decrypt but
**cooperative/bypassable** completeness — a developer inspection tool. Trigon
`--audit` is **enforced/unbypassable completeness + destination-only depth by
default** — a compliance artifact. Carry this framing into the README.
