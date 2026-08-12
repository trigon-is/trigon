# Requirements — M7 `--audit` Network Audit Log

## Intent Analysis
- **User request**: Design and implement `--audit` — a network audit log for Trigon
  container sessions (the M7 roadmap feature + its G6 egress-allow-list sibling).
- **Request type**: New Feature
- **Scope estimate**: Single-Component (the `trigon-up.sh` launcher + one generated
  compose fragment / sidecar), with a session-end summary helper.
- **Complexity estimate**: Moderate.
- **Depth**: Comprehensive (security-sensitive; enforced security extension).

## Decisions from clarifying questions

| Q | Decision | Consequence |
|---|----------|-------------|
| 1 | **Observe-only** — log egress + session summary, never block | No allow-list enforcement in scope; runtime traffic is not gated |
| 2a (completeness) | **Enforced gateway** — agent has no direct route out; the audit sidecar is its only path to the internet (reuses the `--air-gap` internal-network + dual-homed-sidecar pattern) | Capture is **unbypassable** and cooperation-independent, even for a hostile agent; removes the old "not a complete proof" caveat. Cost: sidecar needs routing/NAT (likely `NET_ADMIN`, scoped to the sidecar only — see NFR-9) |
| 2b (depth) | **Destination-only by default** (SNI/host + bytes, no decryption); **`--audit-decrypt` opt-in** for full path/header/body visibility (mitmproxy MitM + injected CA) | Default proves *where* traffic went without reading content (compliance-friendly, no PII exposure); decrypt available when richer detail is worth the CA-injection + cert-pinning risk |
| 3 | **Refuse** `--audit` + `--playwright` | Launch-time guard (not runtime blocking); avoids the host-netns blind spot |
| 4 | **JSON Lines** in `audit-log/` + human-readable session summary | Machine log + DPO-readable summary |
| 5 | **N/A this cycle** — allow-list deferred | G6 enforcement is a later cycle |
| 6 | **Strictly opt-in** (`--audit`, default off) | No implicit behavior change to existing runs |
| 7 | **Full cycle** — implement in `trigon-up.sh` + tests | This AI-DLC cycle runs through Construction (code), not just the design doc |
| 8 | Security extension **enforced** | SECURITY rules are blocking constraints |
| 9 | Resiliency extension **skipped** | Fail-open/closed handled directly (see NFR-5) |
| 10 | PBT **partial** | PBT-02/03/07/08/09 enforced; log serializer/parser is the target |

> **Scope note flagged for the approval gate:** the original ask was "write a new
> doc," but Q7=B expands this cycle to a full implementation of `--audit` in
> `trigon-up.sh` plus tests. Confirm this is intended before we leave Inception.

---

## Functional Requirements

- **FR-1 — `--audit` flag.** `trigon-up.sh` gains a `--audit` flag (default off).
  When set, the agent's outbound traffic is routed through an audit proxy and
  recorded. Documented in `--help` and the flags table.
- **FR-2 — Audit gateway sidecar.** An audit proxy/gateway is attached as a
  runtime-generated compose fragment (the existing `mktemp_yml` + `COMPOSE_FILES`
  + cleanup-trap pattern; the `--air-gap` fragment is the topology template and
  the litellm fragment the sidecar-shape template).
- **FR-3 — Enforced routing (unbypassable).** The agent container is placed on an
  internal network with **no direct route to the internet**; the audit sidecar is
  **dual-homed** (internal + external) and is the agent's only egress path. All
  outbound IP traffic — HTTP, HTTPS, or otherwise, whether or not the agent
  cooperates — MUST traverse the sidecar. This does **not** rely on
  `HTTP_PROXY`/`HTTPS_PROXY` env being honored by the agent.
- **FR-3b — Decryption is opt-in.** By default the gateway records **destination
  metadata only** (host via SNI/CONNECT + byte volume) and does not decrypt.
  `--audit-decrypt` enables full TLS interception (mitmproxy MitM), injecting the
  session CA into the agent's trust store (e.g. `NODE_EXTRA_CA_CERTS` for the
  Node-based Claude Code agent) to capture paths/headers/status.
- **FR-4 — Structured log.** Each observed connection/request is written as one
  JSON Lines record. **Default (destination-only):** ISO-8601 timestamp,
  destination host, destination port, and byte counts (req/resp). **With
  `--audit-decrypt`:** additionally HTTP method, request path, and response
  status. Schema versioned; records note whether they are metadata-only or
  decrypted.
- **FR-5 — Session summary.** At session end, a human-readable summary
  (unique destinations, request counts, total bytes, first/last timestamps) is
  written alongside the JSONL log in `audit-log/` in the mounted project dir.
- **FR-6 — Observe-only.** The proxy records but never blocks a request based on
  destination (allow-list enforcement is explicitly out of scope, Q1=A/Q5=D).
- **FR-7 — Host-networking guard.** `--audit` + `--playwright` **refuses to
  launch** with a clear error (mirrors `--air-gap` × `--playwright`), because a
  host-netns container's traffic cannot be observed by a compose-level proxy.
- **FR-8 — Compose with existing sidecars.** `--audit` must compose correctly
  with the litellm sidecar (tier-2 providers) and with `--playwright-headless`;
  interactions defined in Application Design.
- **FR-9 — `--air-gap --audit`.** Must run and produce an (essentially empty)
  log; the summary states "0 outbound requests" as a positive zero-egress proof.
  With the enforced gateway (FR-3), `--audit` alone already captures *all* egress;
  `--air-gap` additionally guarantees the external leg is severed.

## Non-Functional Requirements

- **NFR-1 — Secret/PII redaction (SECURITY-03).** The **default destination-only**
  mode records no paths/headers/bodies, so it carries minimal PII/secret risk by
  construction. **When `--audit-decrypt` is enabled,** the log writer MUST redact
  credentials and obvious PII — `Authorization`/`Proxy-Authorization` headers, API
  keys, and query-string tokens MUST NOT be written — and MUST never record
  request/response bodies.
- **NFR-2 — Cert-pinning compatibility.** The design MUST address the risk that
  the agent pins certificates or ignores `HTTP_PROXY`/custom CAs (esp. Claude
  Code / Node undici). Requires a documented verification step and a fallback if
  interception breaks the agent's own provider calls.
- **NFR-3 — Completeness by construction.** Because the gateway is enforced at the
  network layer (FR-3), the agent has no alternate route out, so **all** IP egress
  is captured regardless of agent cooperation — the log *is* a complete record of
  outbound destinations. Residual honest limitations to document: (a)
  destination-only mode cannot see intra-TLS content (by design); (b) hostnames
  rely on SNI/DNS (an IP-literal connection is logged by IP); (c) the guarantee
  holds only for the enforced-gateway topology, which is why FR-7 refuses
  host-networking rather than degrading silently.
- **NFR-4 — Log tamper-resistance (SECURITY-14).** The audited agent MUST NOT be
  able to silently rewrite its own audit trail. The log is written by the proxy
  sidecar (not the agent); the design SHOULD place/own the log so the agent
  container cannot freely modify prior records (e.g. sidecar-owned path/volume).
- **NFR-5 — Failure behavior (fail-closed default).** If the proxy fails to
  start, `--audit` MUST fail closed — the session does not launch unaudited by
  surprise. A documented `--audit-allow-degraded` (or equivalent) may opt into
  fail-open; default is fail-closed.
- **NFR-6 — Pinned proxy image (SECURITY-10).** The mitmproxy sidecar image MUST
  be pinned (digest or explicit version), not `latest`, consistent with G9.
- **NFR-7 — Cleanup.** All generated fragments, temp configs, and the CA material
  MUST be removed by the existing cleanup trap on `EXIT/INT/TERM`.
- **NFR-8 — Testability.** `--dry-run` must surface the audit fragment for
  assertion without Docker; new `tests/cli/audit.bats` + a host-side unittest for
  the summary/parse helper. PBT (partial) applies to the log serializer/parser.
- **NFR-10 — Completeness vs. decryption are not equally strong.** Completeness
  (FR-3) is a *hard* guarantee imposed by routing — unbypassable even by a hostile
  agent. Decryption (FR-3b) is *soft* and cooperative — it only works if the
  agent's TLS client accepts the injected CA, and a hostile agent can defeat it
  while remaining fully enforced (cert pinning / CA rejection, application-layer
  encryption, or opaque protocols like QUIC/DNS-tunnelling). Therefore:
  - `--audit-decrypt` MUST NOT be described as an anti-exfil control or as
    "unbypassable"; only completeness earns that claim. It provides richer
    visibility into **honest** flows, layered on the hard guarantee.
  - Real containment against a hostile agent is **completeness + `--air-gap`**
    (deny egress) or the future **G6 allow-list** (permit only known
    destinations) — not decryption.
  - **Decrypt-failure policy (design knob):** when a MITM is refused (pinning),
    the gateway MUST choose per documented policy between **fail-closed** (drop
    the flow — safe but may break the agent's real work) and **pass-through
    SNI-only** (tunnel opaque, log destination only — keeps functionality,
    degrades depth for that flow, never a bypass). Default TBD in Application
    Design; both preserve completeness.
- **NFR-9 — Least-privilege gateway (SECURITY-06, threat-model G8).** The
  transparent routing/NAT the enforced gateway needs (likely `NET_ADMIN`) MUST be
  confined to the **audit sidecar only** — never granted to the agent container.
  Grant the minimum capability set required; drop all others. Revisit whether
  full `NET_ADMIN` is needed or a narrower mechanism suffices during design.

## Security Compliance Summary (Security Baseline — enforced)

| Rule | Status | Note |
|------|--------|------|
| SECURITY-01 Encryption at rest/transit | N/A | No data store; log is a local file |
| SECURITY-02 Access logging on intermediaries | **Compliant (by design)** | The proxy *is* the access log (FR-4) |
| SECURITY-03 App logging / no secrets in logs | **Addressed** | NFR-1 redaction |
| SECURITY-04 HTTP security headers | N/A | No HTML endpoints |
| SECURITY-05 Input validation | Applies (light) | Validate `--audit`-related flag values / allow-list path if added later |
| SECURITY-06 Least privilege | Applies | Proxy sidecar caps/network scoped minimally |
| SECURITY-07 Restrictive network config | **Addressed** | Agent routes only via proxy; FR-7 refuses host-net |
| SECURITY-08 App access control | N/A | No multi-user app |
| SECURITY-09 Hardening/misconfig | Applies | No default creds in generated mitmproxy config |
| SECURITY-10 Supply chain | **Addressed** | NFR-6 pinned image |
| SECURITY-11 Secure design | **Addressed** | Threat-model-driven; misuse case = agent tampering (NFR-4) |
| SECURITY-12 Auth/credentials | N/A | No user auth |
| SECURITY-13 Integrity verification | Applies | Pin image by digest; CA generated per-session |
| SECURITY-14 Alerting/log integrity | **Addressed** | NFR-4 tamper-resistance |
| SECURITY-15 Fail-safe defaults | **Addressed** | NFR-5 fail-closed |

No blocking security findings at Requirements stage — applicable rules are carried
as NFRs/design constraints.

## Prior Art — VibePod (verified 2026-08-12)

Verified against `github.com/VibePod/vibepod-proxy`, `vibepod-agents`, and
`vibepod.dev/docs` (not just secondary summaries):

- **Depth:** full HTTPS **MITM decryption** via mitmproxy; the agent entrypoint
  appends the proxy CA to `/etc/ssl/certs/ca-certificates.crt`, so it reads full
  URLs/headers/bodies, logged to SQLite (Datasette UI), attributed per container.
- **Completeness:** **cooperative** forward proxy at `http://vibepod-proxy:8080`
  (container-name DNS). No iptables/transparent/gateway enforcement found in any
  repo or doc; disableable via `VP_PROXY_ENABLED=false`. Therefore **bypassable**.

Implication: VibePod is *more invasive on depth* (always decrypts) but *weaker on
completeness* (evadable) — a **developer traffic-inspection** tool. Trigon's
`--audit` is deliberately the inverse: **enforced/unbypassable** completeness with
**destination-only** depth by default — a **compliance artifact**. This is the
evidenced differentiation to carry into the design doc and README.

## Out of Scope (this cycle)
- G6 egress **allow-list enforcement** (Q1=A/Q5=D) — future cycle. Note: the
  enforced-gateway topology is the natural substrate for it later (block instead
  of just log), which is the intended G6 growth path.
- Request/response **body capture** — never (NFR-1); `--audit-decrypt` captures
  metadata (paths/headers/status) only.
- Non-IP / L2 concerns beyond what the gateway routes.

## Open Design Questions (for Application Design)
- Exact enforced-gateway mechanism in Docker Compose: how the agent's default
  route is forced through the sidecar (transparent-proxy image + `NET_ADMIN` NAT,
  vs. an internal network where the sidecar is the sole dual-homed member), and
  the minimum capability that achieves it (NFR-9).
- Gateway ordering when the litellm sidecar is present (agent → audit gateway →
  litellm → provider, vs. audit gateway wraps both).
- Where the CA is generated and trusted per-agent (Node vs others) — only on the
  `--audit-decrypt` path.
- Log ownership/volume to satisfy NFR-4 without a big UX cost.
- Whether `--playwright-headless` (in-container Chromium) egress routes through
  the gateway too (it stays namespaced, so it should).
