# AI-DLC State Tracking

## Project Information
- **Project Type**: Brownfield
- **Feature**: M7 — `--audit` network audit log (+ G6 egress allow-list)
- **Start Date**: 2026-08-11T13:36:55Z
- **Last Updated**: 2026-09-30
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

**▶ OPEN ISSUES — start here next session:**
2. **Log lands in the agent-accessible project dir (NFR-4 gap).** Sidecar writes to
   a private `mktemp` dir (tamper-safe during the run), but `trigon-up.sh` copies
   it to `<project>/audit-log/` at session end → a *later* agent session on the
   same project can read/alter old logs. Decide a non-agent-mounted destination
   (e.g. `~/.trigon-audit/<name>/`, NOT `~/.trigon-settings-<name>` which is also
   mounted). Open design decision, not yet changed.

**Found while fixing #1 (new, open):**
- **Coverage gap:** only TCP :80/:443 are redirected. Other TCP ports, UDP (DNS,
  QUIC) and IPv6 leave unlogged and unblocked — contradicts the "ALL egress"
  claim in `--help`/README.
- **Concurrent sessions collide:** every `--audit` session uses the same
  `compose-audit-gw-1`; a second session recreates it and finalize now removes
  it. Needs a per-session gateway/project name. One audited session at a time
  until then.

**Also before merge:**
3. Verify the remaining M7 gates (#1 is fixed): `--audit-decrypt` doesn't break
   Claude Code's own provider calls (Node CA trust); `--air-gap --audit`
   zero-egress; `--playwright-headless` egress transits the gateway.
4. Pin the base image by digest (`MITMPROXY_BASE` in `compose/audit/Dockerfile`, NFR-6).
5. Run `tests/cli/audit.bats` under `bats` + shellcheck; then open PR.

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
