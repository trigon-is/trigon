# Application Design Plan — M7 `--audit`

**Stage**: INCEPTION — Application Design
**Deliverable**: `docs/audit-design.md` (consolidated; Functional/NFR/Infra design folded in).
**Created**: 2026-08-13

## Design plan (checklist)

- [ ] Resolve the open design decisions below (D1–D6) with the user.
- [ ] Component definitions — the audit gateway sidecar, the launcher flag/fragment
  logic, the summary/parse helper (`lib/audit_summary.py`).
- [ ] Component methods / interfaces — flag surface, generated fragment shape, env
  injected into the agent, JSONL record schema (versioned), summary format.
- [ ] Service orchestration — compose ordering vs. litellm + playwright-headless;
  fail-closed startup; cleanup.
- [ ] Component dependencies + data flow — agent → gateway → internet; log volume
  ownership; CA trust path (decrypt only).
- [ ] NFR design mapping (redaction, tamper-resistance, least-privilege, pinning,
  fail-closed, cert-pinning fallback) tied to each NFR-1…10.
- [ ] Test design (dry-run fragment assertions; host-side serializer + PBT).
- [ ] Validate completeness/consistency, then write `docs/audit-design.md`.

## Open design decisions (need user input)

### D1 — Enforced-routing mechanism (the core decision; NFR-3, NFR-9)
FR-3 requires egress capture that does **not** rely on the agent honoring
`HTTP(S)_PROXY`. Two candidate mechanisms:

- **(A) Transparent gateway** — agent on an `internal` network; audit sidecar
  dual-homed (internal + default), granted **NET_ADMIN (sidecar only)**, runs
  iptables REDIRECT + is the agent's route out. mitmproxy in `--mode transparent`.
  *All* IP egress is forwarded **and logged** (hostnames via SNI even with no proxy
  env). Strongest / most literal to FR-3. Cost: NET_ADMIN on the sidecar, more
  moving parts, needs live verification that the agent's default route can be
  pinned to the sidecar without granting the agent NET_ADMIN.
- **(B) Internal-net + explicit proxy (drop-by-default)** — agent on an `internal`
  network (no direct egress at all); sidecar dual-homed is the *only* member that
  can reach outside; agent gets `HTTP(S)_PROXY` → the sidecar. Honest traffic is
  proxied and logged with hostnames; **non-proxied traffic is dropped by the
  internal network** (it cannot escape, so nothing exfiltrates unlogged). No
  NET_ADMIN needed. Weaker in that a hostile agent's non-proxy attempts are
  *dropped* rather than *logged by IP* (you see failures/CONNECTs, not a clean
  destination line), and it leans on proxy env for the honest path.

[Answer]: **A — transparent gateway** (NET_ADMIN scoped to sidecar). B (internal-net+proxy) is documented as the fallback if A proves infeasible in pure Compose. Decided 2026-08-15. Note: completeness (A) and decryption depth are orthogonal — A logs *all* destinations incl. a hostile agent's; decrypt (opt-in) reveals only honest, CA-accepting flows.

### D2 — Decrypt-failure default policy (NFR-10 design knob)
When `--audit-decrypt` is on and a flow refuses the MITM (cert pinning), the
gateway must either:
- **fail-closed** — drop the flow (safe, but may break the agent's real work), or
- **pass-through-SNI** — tunnel it opaque, log destination only (agent keeps
  working; depth degrades for that flow; completeness preserved).

Both preserve completeness. Which is the **default**? (a `--audit-*` flag can select
the other.)

[Answer]: **pass-through-SNI default** — honest content decrypted; pinned/hostile flows tunneled opaque but still logged by destination (completeness preserved). `--audit-decrypt-fail-closed` opts into dropping refused flows. Decided 2026-08-15.

### D3 — Log ownership / tamper-resistance (NFR-4)
The primary project mount `${PROJECT_ROOT}:/app` is agent-writable, so writing the
log there lets the agent rewrite its own trail. Options:
- **(A) Sidecar-only bind mount** — a dedicated `audit-log/` dir bind-mounted into
  the **gateway sidecar only**, not the agent. Live during the session, agent
  can't touch it. (Recommended.)
- **(B) Sidecar-owned Docker volume, exported at session end** — strongest
  isolation; log only materializes in the project after the run.
- **(C) Write into the agent-visible project dir** — weakest; agent can tamper.

[Answer]: **A — sidecar-only bind mount** (`audit-log/` mounted into the gateway only, not the agent; live + tamper-resistant). Decided 2026-08-15.

### D4 — Proxy image + pinning (NFR-6, SECURITY-10/13)
Default: **`mitmproxy/mitmproxy` pinned by digest** (covers both destination-only
transparent mode and the `--audit-decrypt` MITM path). Confirm, or prefer a
lighter custom logging proxy for the destination-only default (would still need
mitmproxy for decrypt).

[Answer]: **mitmproxy pinned-by-digest** for both destination-only and decrypt paths (one image). Decided 2026-08-15.

### D5 — `--playwright-headless` + `--audit`
Headless Chromium stays in the container netns, so its egress should route through
the gateway like any other agent traffic. Confirm we **allow** the combo (route it
through) rather than refuse it. (Full `--playwright`/host-net is already refused by
FR-7.)

[Answer]: **Allow** — route headless Chromium egress through the gateway (stays namespaced). Decided 2026-08-15.

### D6 — Fail-closed knobs & flag names
NFR-5 fail-closed default; opt-out `--audit-allow-degraded`. Confirm the flag
surface: `--audit`, `--audit-decrypt`, `--audit-allow-degraded`, and (if D2 default
is pass-through) `--audit-decrypt-fail-closed` for the strict variant.

[Answer]: **Four flags:** `--audit`, `--audit-decrypt`, `--audit-allow-degraded`, `--audit-decrypt-fail-closed`. Decided 2026-08-15.

## Fixed decisions (from requirements — not re-opened)
- Opt-in, default off; JSONL + human summary in `audit-log/`; refuse `--audit` +
  `--playwright` (FR-7); `--air-gap --audit` → zero-egress proof (FR-9); no body
  capture ever (NFR-1); redaction on decrypt path; completeness is hard, decryption
  is soft (NFR-10).
