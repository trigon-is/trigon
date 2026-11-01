# AI-DLC Audit Trail — M7 `--audit` feature

Complete, append-only log of interactions for this AI-DLC cycle. Raw user input
is captured verbatim, never summarized.

---

## Workspace Detection / Cycle Kickoff
**Timestamp**: 2026-08-11T13:36:55Z
**User Input**: "I think I want you to conclude the security-hardening for now. And prepare to write a new doc for the audit feature. I would like to take a sort of aidlc dev cycle on that. I have merged the security-hardening into master. So we can start a inception phase on the audit feature."
**AI Response**: Confirmed `master` carries the security-hardening merge (PR #3, `17b0b23`), created branch `feature/audit-inception`, recorded a security close-out note in `docs/session-start.md` (four controls merged; live-container verification parked). Asked two setup questions (ceremony level, docs location).
**Context**: INCEPTION — Cycle kickoff.

---

## Setup Decisions
**Timestamp**: 2026-08-11T13:36:55Z
**User Input**: Ceremony = "Full ceremony"; Docs location = "Under docs/".
**AI Response**: Established full-ceremony AI-DLC with artifacts under `docs/audit/`. Ran Workspace Detection (brownfield), created `aidlc-state.md` and this `audit.md`, and produced scoped reverse-engineering artifacts for the networking/egress subsystem.
**Context**: INCEPTION — Workspace Detection complete; entering Reverse Engineering.

---

## Reverse Engineering — Approval Gate
**Timestamp**: 2026-08-11T13:36:55Z
**AI Response**: Presented scoped RE artifacts (architecture.md, code-structure.md, timestamp) for the networking/egress subsystem; asked for Request Changes / Approve & Continue.
**User Input**: "Approve and continue"
**Context**: INCEPTION — Reverse Engineering approved. Proceeding to Requirements Analysis.

---

## Requirements Analysis — Clarifying Questions Posed
**Timestamp**: 2026-08-11T13:36:55Z
**AI Response**: Intent analysis: New Feature / Single-Component / Moderate complexity / incomplete request. Created `inception/requirements/requirement-verification-questions.md` with 7 substantive questions + 3 extension opt-in questions (security, resiliency, property-based testing). Awaiting user answers via [Answer]: tags.
**User Input**: (answered — see below)
**Context**: INCEPTION — Requirements Analysis, Step 6 gate (awaiting answers).

---

## Requirements Analysis — Answers Received & Analyzed
**Timestamp**: 2026-08-11T13:36:55Z
**User Input**: Q1:A, Q2:A, Q3:A, Q4:A, Q5:D, Q6:A, Q7:B, Q8:A, Q9:B, Q10:B (verbatim letter answers in `requirement-verification-questions.md`).
**AI Response**: Ran mandatory contradiction/ambiguity analysis. No blocking contradictions. Surfaced constraints from Q2=A (TLS decryption) × Q8=A (security enforced): NFR-1 secret/PII redaction (SECURITY-03), NFR-4 log tamper-resistance (SECURITY-14), NFR-2 cert-pinning risk, NFR-3 coverage-completeness limitation, NFR-6 pinned image (SECURITY-10). Loaded enabled extension rule files (security-baseline.md, property-based-testing.md). Recorded Extension Configuration. Wrote `requirements.md`. Flagged Q7=B scope expansion (doc → full implementation) for the approval gate.
**Context**: INCEPTION — Requirements Analysis complete; awaiting approval.

---

## Requirements Analysis — Revision (enforced gateway + destination-only default)
**Timestamp**: 2026-08-11T13:36:55Z
**User Input**: "Update requirements: enforced gateway, destination-only default with decrypt opt-in" (+ aside asking how VibePod handles inspection depth / completeness).
**AI Response**: Explained SNI, proxy-aware traffic, and the completeness-vs-depth split. Revised `requirements.md`: split Q2 into Axis A (completeness) = enforced gateway (unbypassable, reuses `--air-gap` topology) and Axis B (depth) = destination-only default + `--audit-decrypt` opt-in. Updated FR-2/3/3b/4/9, NFR-1/3, added NFR-9 (least-privilege gateway, NET_ADMIN scoped to sidecar; G8-aware), refreshed out-of-scope + open design questions. Answered VibePod aside from repo notes (grounded, with uncertainty flagged).
**Context**: INCEPTION — Requirements Analysis revised; awaiting approval.

---

## Requirements Analysis — VibePod Verification
**Timestamp**: 2026-08-12
**User Input**: "Verify VibePod's exact behavior against their actual repo/docs."
**AI Response**: Web-verified via vibepod-proxy, vibepod-agents (claude entrypoint.sh), vibepod-cli, vibepod.dev/docs, agent-wars. Findings: depth = full mitmproxy MITM decrypt (CA appended to ca-certificates.crt; logs to SQLite/Datasette); completeness = cooperative forward proxy (http://vibepod-proxy:8080, no iptables/transparent enforcement found, disableable via VP_PROXY_ENABLED=false → bypassable). Cooperative conclusion is a strong inference (no transparent-routing found); decrypt conclusion directly evidenced. Added a "Prior Art — VibePod (verified)" section to requirements.md; differentiation = Trigon is inverse (enforced completeness + destination-only depth by default).
**Context**: INCEPTION — Requirements Analysis; prior-art verified; awaiting approval.

---

## Requirements Analysis — Completeness-vs-Decryption Clarification
**Timestamp**: 2026-08-12
**User Input**: "could a theoretical --audit-decrypt implementation also be un-bypassable? or is there some conflict there?"
**AI Response**: Explained the two are orthogonal (can coexist) but asymmetric: completeness = routing-imposed → unbypassable; decryption = TLS-trust → cooperative, defeatable by a hostile agent (cert pinning, app-layer encryption, opaque protocols) while still enforced. Added NFR-10: --audit-decrypt must not be marketed as unbypassable; containment = completeness + air-gap / future G6 allow-list; decrypt-failure policy (fail-closed vs pass-through-SNI) is a design knob (both preserve completeness).
**Context**: INCEPTION — Requirements Analysis; NFR-10 added; awaiting approval.

---

## Context-Clear Checkpoint
**Timestamp**: 2026-08-12
**User Input**: "record the current state of play in the relevant docs and session primer files, in preparation of clearing context."
**AI Response**: Updated `aidlc-state.md` (added Last Updated, Branch, RESUME POINT block with next action + locked decisions) and `docs/session-start.md` (2026-08-12 entry pointing to the `docs/audit/` artifacts and the requirements approval-gate pause). No commit made (working tree on `feature/audit-inception`). Workflow remains paused at the Requirements approval gate.
**Context**: INCEPTION — Requirements Analysis; checkpoint for context clear.

---

## Side Artifact — Conceptual Reference Doc
**Timestamp**: 2026-08-12
**User Input**: "Record for me now some documentation on the questions we have been discussing previously wrt. completeness and audit-depth ... not for the purposes of development but for understanding and reasoning."
**AI Response**: Created `docs/audit-concepts.md` (human-facing reference, outside the AI-DLC artifact tree): two orthogonal axes (completeness/depth), SNI + proxy vocabulary, the hard-vs-soft guarantee asymmetry, the hostile-agent lens (what can/can't be defeated), containment via completeness + air-gap/allow-list, the decrypt-failure tension, and the VibePod comparison. Added a pointer in `docs/README.md`. This is a reasoning artifact, not a workflow stage — the Requirements approval gate remains the active pause point.
**Context**: INCEPTION — reference doc created; workflow still paused at Requirements approval gate.

---

## Requirements Analysis — Approval Gate
**Timestamp**: 2026-08-13T14:44:18Z
**AI Prompt**: Presented the Requirements approval gate (Approve & continue / Request changes / Add User Stories / Design doc only), summarizing the locked decisions (enforced gateway, destination-only default + `--audit-decrypt` opt-in, NFR-10 hard-vs-soft asymmetry, refuse `--audit`+`--playwright`, fail-closed, VibePod prior art) and flagging the Q7=B full-implementation scope + the proposal to skip User Stories.
**User Response**: "Approve & continue"
**Status**: Approved — requirements accepted as-is; full-implementation scope confirmed; User Stories to be skipped.
**Context**: INCEPTION — Requirements Analysis approved; advancing to Workflow Planning.

---

## Workflow Planning — Execution Plan Created
**Timestamp**: 2026-08-13T14:44:18Z
**AI Response**: Loaded RE artifacts (architecture.md networking/egress) + `requirements.md`. Ran detailed scope/impact/risk analysis (brownfield, single-component app change + infra sidecar; Medium risk from networking unknowns NFR-9/NFR-2; Easy rollback — opt-in). Wrote `inception/plans/execution-plan.md` with workflow visualization. Determination: EXECUTE = Application Design (→ `docs/audit-design.md`), Code Generation, Build & Test; SKIP = User Stories (single persona), Units Generation (single component), NFR Requirements (already NFR-1…10); FOLD into Application Design = Functional/NFR/Infrastructure Design (one bash CLI + one compose fragment). Awaiting approval at the Workflow Planning gate.
**Context**: INCEPTION — Workflow Planning complete; awaiting approval to enter Application Design.

---

## Workflow Planning — Approval Gate
**Timestamp**: 2026-08-13
**AI Prompt**: Presented the Workflow Planning gate (Approve & continue / Request changes / Add skipped stages), summarizing EXECUTE vs SKIP vs FOLD determinations and the Medium risk / Easy rollback assessment.
**User Response**: "Approve & continue"
**Status**: Approved — advancing to Application Design.
**Context**: INCEPTION — Workflow Planning approved.

---

## Application Design — Design Decisions Elicited
**Timestamp**: 2026-08-15
**AI Response**: Grounded the design in the actual code (fragment pattern, air-gap `:667-701` + litellm `:419-446` templates, base.yml cap_drop ALL, `${PROJECT_ROOT}:/app` agent-writable mount, `--dry-run` test hook). Wrote `inception/plans/application-design-plan.md` with six design decisions (D1 routing mechanism, D2 decrypt-fail policy, D3 log ownership, D4 proxy image, D5 headless combo, D6 flag surface). Posed the three consequential ones + a defaults bundle via AskUserQuestion.
**User Input**: First declined to clarify — asked to untangle the "A then B" fallback and whether completeness (hostile-destination logging) and decryption (honest-flow depth) can coexist.
**AI Response**: Explained the two orthogonal axes (completeness=routing, unbypassable, all traffic incl. hostile; depth=decryption, cooperative, honest flows only), corrected that "A then B" was a fallback *within* the completeness axis (not completeness-vs-decrypt), and confirmed a single mitmproxy sidecar delivers both (all destinations logged + honest content decrypted, pinned/hostile flows pass-through-logged). Re-posed the decisions.
**User Input**: D1+D2 = "Yes, record A + pass-through"; D3 = "Sidecar-only bind mount"; D4–D6 = "Accept all recommended".
**AI Response**: Recorded all answers into the plan; wrote the consolidated design deliverable `docs/audit-design.md` (topology, components C1–C3, JSONL schema v1, flag surface, orchestration/fail-closed, NFR-1…10 mapping, test design, Construction open items). Updated `aidlc-state.md`.
**Context**: INCEPTION — Application Design complete; awaiting approval to enter CONSTRUCTION.

---

## Application Design — Approval Gate
**Timestamp**: 2026-08-15
**AI Prompt**: Presented the Application Design gate (Approve & start Construction / Request changes / Add Units Generation), summarizing the design deliverable.
**User Response**: "Approve & start Construction"
**Status**: Approved — advancing to CONSTRUCTION → Code Generation.
**Context**: INCEPTION complete; entering CONSTRUCTION.

---

## Construction — Code Generation + Build & Test
**Timestamp**: 2026-08-15
**AI Response**: Implemented `--audit` end to end, grounded in the existing code (fragment pattern, air-gap/litellm templates, `--dry-run` hook). Chose `network_mode: "service:audit-gw"` (shared netns) as the enforced-routing mechanism — the agent uses the sidecar's network stack, so uid-owner iptables REDIRECT in the sidecar captures all agent egress while the agent keeps `cap_drop: ALL` (NFR-9 satisfied, resolves the design's route-pinning crux without granting the agent NET_ADMIN). Files: `compose/audit/entrypoint.sh` + `compose/audit/audit_addon.py` (mitmproxy addon: SNI/destination-only default via `tls_clienthello` ignore; decrypt records with query-strip redaction; pass-through-SNI vs fail-closed), `lib/audit_summary.py` (host-side summary, stdlib-only), `trigon-up.sh` (4 flags, guards, generated fragment, decrypt CA injection via `NODE_EXTRA_CA_CERTS`, sidecar-only log dir + post-run finalize/summary + cleanup), `tests/cli/audit.bats`, `tests/test_audit_summary.py` (unit + PBT), README (flags + Network audit log section + M7 status), `.gitignore` (`audit-log/`). Verified: `bash -n`, `sh -n`, dry-run behavior for all flags/guards/combos incl. `--air-gap --audit` (no network_mode conflict), full 26-test python suite green. **Parked (no Docker in dev):** live-container verification of enforced routing + decrypt + zero-egress, digest-pin of the mitmproxy image, `bats`/shellcheck runs. `--audit` is code-complete.
**Context**: CONSTRUCTION — Code Generation + Build & Test complete (host-verified); live-container verification parked.

---

## Construction — Live-Test Fix #1: gateway image (iptables)
**Timestamp**: 2026-08-15
**User Input**: Ran `./trigon-up.sh ... --playwright-headless --yolo --audit`; `audit-gw` exited 127 ("dependency failed to start"). Then confirmed via `docker run --rm --entrypoint sh mitmproxy/mitmproxy:11.1.3 -c 'command -v iptables || echo NO-IPTABLES; command -v mitmdump'` → `NO-IPTABLES` + mitmdump present. Chose Path A (build a pinned custom image, keep enforced/transparent D1-A).
**AI Response**: Diagnosed: the stock mitmproxy image ships mitmdump but not `iptables`, so the transparent-gateway entrypoint dies with 127 under `set -e` before mitmdump starts. Implemented the purpose-built image: `compose/audit/Dockerfile` (FROM mitmproxy/mitmproxy:11.1.3 + iptables + procps), `build.sh --audit-gateway` → `trigon-audit-gw:latest`, changed the default `TRIGON_AUDIT_IMAGE` to that tag, and added a launch-time fail-closed preflight (`docker image inspect`) that refuses to run `--audit` if the image is missing. Updated design doc D4/C2, README, aidlc-state. Host-verified (bash -n, dry-run, 26 tests). Handed the user the rebuild + re-run commands.
**Context**: CONSTRUCTION — live-test iteration; awaiting user rebuild + re-run.

---

## Construction — Live-Test Fix #2: sidecar file perms (DAC_OVERRIDE)
**Timestamp**: 2026-08-15
**User Input**: After the image fix, `audit-gw` got further (iptables OK, mitmdump started) then exited 1 with `PermissionError: [Errno 13] Permission denied: '/audit-log/.mitmproxy/...'` (command_history, mitmproxy-ca.pem, config.yaml).
**AI Response**: Diagnosed the interaction with our own hardening: the sidecar runs uid 0 but `cap_drop: ALL` strips CAP_DAC_OVERRIDE, so root can no longer bypass file-permission bits — and `/audit-log` is a host `mktemp` dir owned by uid 1000 (not 0), so uid-0 writes are refused (iptables still worked because it only needs the granted NET_ADMIN). Fix: add `DAC_OVERRIDE` to the sidecar `cap_add` (now `[NET_ADMIN, DAC_OVERRIDE]`, still `cap_drop: ALL`) — the minimum set to manipulate netfilter and write the log/CA to the host-owned mount. Updated the NFR-9 design mapping + addon docstring. Awaiting user re-run.
**Context**: CONSTRUCTION — live-test iteration #2; awaiting user re-run.

---

## Construction — Live-Test #3: gateway healthy, but two open issues surfaced
**Timestamp**: 2026-08-15
**User Input**: After the DAC_OVERRIDE fix, the run succeeded — `compose-audit-gw-1` reached Healthy, the agent ran a full ~7.5 min Claude session, and log+summary were written to `/home/bergurth/test_proj/audit-log/`. BUT: internet was accessible from the container, the JSONL is **empty**, and the summary reads "0 outbound requests — zero-egress verified." User flagged (a) surprise that the log lands in the agent-accessible project dir, and (b) that the log records nothing. Asked to record state + commit the branch (everything but .claude) to resume later.
**AI Response**: Confirmed both are real. (1) Empty-log = traffic is bypassing interception, not absent — leading hypotheses: iptables `nft`-vs-`legacy` backend mismatch making the REDIRECT rules inert (agent egresses directly), or the destination-only path emitting no event because the addon writes in `tcp_end` (which may not fire for `ignore_connection=True` flows) rather than in `tls_clienthello`. (2) Log-location = a half-implemented D3: the sidecar writes to a private mktemp dir (tamper-safe during the run) but trigon-up.sh copies it into `<project>/audit-log/` at session end, so a later session's agent could tamper — should land outside the agent-mounted paths (e.g. `~/.trigon-audit/<name>/`). Recorded both as the next-session open issues in `aidlc-state.md`; did NOT change behavior yet. Committing the branch per request.
**Context**: CONSTRUCTION — gateway functional; interception-capture + log-location issues deferred to next session. State recorded; branch committed.

---

## Construction — Completion plan for the remaining work
**Timestamp**: 2026-10-05
**User Input**: Asked for an assessment of what remains (full port coverage, issue 2 log location, concurrent sessions), its feasibility and difficulty, aiming for a meritorious completion of the feature. Approved the proposed log location; asked whether blocking UDP/QUIC would hurt agent harnesses; asked to record the plan for the next session.
**AI Response**: Found a new hole: `--audit` + `--root` runs the agent as uid 0, which the gateway's uid-0 RETURN rule exempts, so a root agent's egress is never redirected or logged. Traced the concurrency collision to `trigon-up.sh` never passing a compose project name. Identified DNS (Docker's embedded resolver at 127.0.0.11) as an unlogged egress channel. Answered on UDP/QUIC: Claude Code (Node) and OpenCode (Bun) don't use HTTP/3; Chromium falls back to TCP; so REJECT-by-default is safe, apart from UDP tools by design. Recorded the four-batch completion plan and decision D7 (log at `${XDG_STATE_HOME:-~/.local/state}/trigon/audit/<project>/`, mount deny-listed, records hash-chained) in `aidlc-state.md`. No code changed.
**Context**: CONSTRUCTION — plan agreed; next session starts Batch 1.

---

## Construction — Batch 1 session start (1a/1b/1c)
**Timestamp**: 2026-10-31
**User Input**: "We are working on Trigon See /app for the general context .. all or at least most paths below are based on /app

We're finishing Batch 1 of the M7 --audit completion plan on branch
  feature/audit-inception.

  Start by reading, in order: CLAUDE.md, docs/session-start.md ("Current state"),
  docs/audit/aidlc-state.md (the "COMPLETION PLAN" section, Batch 1 = items 1a, 1b, 1c),
  and docs/threat-model.md (we're touching guards, mounts and the audit log).
  The repo may be mounted somewhere other than /app; use absolute paths.

  This is the CONSTRUCTION stage of an approved AI-DLC cycle: the plan and decision D7 were
  approved on 2026-10-05, so no new approval gates are needed. Keep aidlc-state.md current
  and append every interaction to docs/audit/audit.md (user input verbatim, append-only).
 
  Do the three items in order, one commit each (the commit message explains why). Don't
  push.

  1a. Refuse --audit together with --root, the same way --playwright is refused. Also
  refuse
      --audit when the host user is uid 0 (id -u = 0, e.g. CI), since the gateway's uid-0
      RETURN rule would leave all agent egress unlogged. Fail closed with a clear message
      citing the threat-model goal. Add bats cases (use --dry-run).
  
  1b. Per-session compose project: pass -p trigon-<name>-<short random> (lowercased and
      sanitized for compose) on every compose call, including the litellm sidecar and
      air-gap paths. Run compose down at exit so per-session networks don't pile up.
      Make sure finalize's \"rm --stop audit-gw\" targets only this session's gateway.
      Check that this fits the per-launch /app_2..N mount fragment from eee8db9.
      Add bats cases showing the -p in the dry-run output.

1c. Decision D7, log location plus tamper evidence:
      - Write logs to ${XDG_STATE_HOME:-$HOME/.local/state}/trigon/audit/<project-slug>/
        (override with TRIGON_AUDIT_DIR), no longer to <project>/audit-log/.
        Directory mode 0700; chmod finished files to 0444.
      - Add that directory to mount_denied_reason() (the G1 deny-list).
      - Hash chain in the addon: every JSONL record carries prev = sha256 of the previous
        line (fixed genesis value); bump the schema to v2. audit_summary.py verifies the
        chain and records the head hash in the summary; trigon-up.sh prints the head hash
        at session end. State in the design doc what the chain does and doesn't guarantee
        (e.g. truncation of the tail is only caught against the printed head hash).
      - Update the requirements wording, README, --help, .gitignore note and 
        docs/audit-design.md §5. Update tests/test_audit_summary.py with chain verification
        plus a property-based test that any single-line edit, delete or reorder is
        detected; update tests/cli/audit.bats.
        
  Run the checks listed in CLAUDE.md. bats and shellcheck may be missing; clone bats-core
  into a scratch dir if needed, and say which checks you skipped. There's no Docker in the
  container, so don't claim live behaviour. Instead, write a short host smoke-test
  checklist
  (the exact commands for me to run on the host) covering: --audit + --root refused, two
  concurrent --audit sessions without a collision, and the log landing in the new dir with
  a
  chain that verifies.

  Finish with a summary: commits, test results, skipped checks, the smoke checklist, and
  3–4 sentences on what the log now guarantees, written so I can paste them into my thesis
  brief for Thursday."
**AI Response**: Read CLAUDE.md, session-start "Current state", aidlc-state COMPLETION PLAN and threat-model.md. Baseline: 40/40 bats green (bats-core cloned to scratch); shellcheck 0.11 (pip wheel, scratch) reports two pre-existing findings in trigon-up.sh (SC2004 line 159, SC2329 `cleanup`). No Docker in the container. Proceeding with 1a → 1b → 1c, one commit each.
**Context**: CONSTRUCTION — Batch 1 in progress.

---

## Construction — Batch 1, item 1a: `--audit` × `--root` / uid-0 guard
**Timestamp**: 2026-10-31
**User Input**: (continues the Batch 1 request above; no new input)
**AI Response**: Added two fail-closed refusals in the `--audit` block of `trigon-up.sh`: `--audit --root`, and `--audit` when `LOCAL_UID` (= `id -u`) is 0. Both cite threat-model G6 and explain the gateway's uid-0 RETURN exemption. `--help` notes the incompatibility. bats: `--root` refused, uid 0 refused (a fake `id` shadowed on PATH, so there is no env-var bypass of the guard), uid 0 without `--audit` still launches. 43/43 bats green; shellcheck findings unchanged (2 pre-existing).
**Context**: CONSTRUCTION — Batch 1, 1a committed.

---

## Construction — Batch 1, item 1b: per-session compose project
**Timestamp**: 2026-10-31
**User Input**: (continues the Batch 1 request above; no new input)
**AI Response**: `trigon-up.sh` now derives `COMPOSE_PROJECT=trigon-<name>-<6 hex>` (name lowercased, chars outside `[a-z0-9_-]` → `-`, a duplicate `trigon-` prefix dropped, capped at 40) and appends `-p` to `COMPOSE_CMD` once, so run, finalize and teardown all share it. These paths are covered: default, litellm, air-gap, audit and multi-path. `cleanup` is idempotent; when a real session ran it calls `audit_finalize` (moved into a function), then `compose down -v --remove-orphans`, and only then removes the fragments. INT/TERM now `exit` (and so run cleanup once via EXIT) instead of resuming the script. Found and fixed while doing this: under `set -e` a non-zero session exit skipped finalize, and `cleanup` then deleted the unexported log. `run_compose` now records the status, and the launcher still exits with it. The `/app_2..N` fragment from eee8db9 is just one more `-f`; `down` runs before temp fragments are removed. bats: 7 new cases (6 dry-run `-p`, 1 stub-`docker` case checking run → `rm --stop audit-gw` → `down` under one project and exit-status passthrough). 51/51 green.
**Context**: CONSTRUCTION — Batch 1, 1b committed.

---

## Construction — Batch 1, item 1c: D7 log location + hash chain
**Timestamp**: 2026-10-31
**User Input**: (continues the Batch 1 request above; no new input)
**AI Response**: Implemented D7.
- **Launcher.** `AUDIT_ROOT` = `${TRIGON_AUDIT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/trigon/audit}`, symlink-resolved even when it doesn't exist yet (`resolve_path`). The per-project dir is `<basename>-<cksum of full path>`. `mount_denied_reason()` refuses the root, anything under it, and any ancestor of it (e.g. `~/.local`), on every launch. `audit_finalize` creates the dirs under umask 077, chmods both to 0700, names files after the per-launch compose project, chmods them 0444 and prints the chain head plus a `--verify` command. If the destination can't be created, it keeps the work dir rather than deleting the log.
- **Addon (schema v2).** Each record carries `prev` = sha256 of the previous line. GENESIS is 64 zeros. Lines are written under the lock, and `tail_hash` resumes the chain after a mitmproxy addon reload.
- **`lib/audit_summary.py`.** A strict `verify_chain`; the summary gets a chain line; with OUTFILE it prints the chain status and exits 1 if the chain is broken; a new `--verify LOG [HEAD]` mode reports MISMATCH when the chain is intact but the head differs (truncation or rewrite).
- **Docs.** design §5.1–5.4 (incl. what the chain does NOT guarantee: tail truncation and wholesale recompute are only caught against the recorded head; it is unkeyed, not a signature; 0444 isn't immutability), D3/D7, NFR-4 mapping, requirements decision 4/FR-5/NFR-4, README, `--help`, `.gitignore` note, threat-model G1 status.
- **Tests.** python 26 → 38, incl. PBT that any single-line edit/delete/reorder is detected (by the chain alone unless only the last line changes; otherwise by the head). A mutation check (verifier's `prev` comparison disabled) fails 4 tests. bats 51 → 56, incl. deny-list (dir, subdir, parent, symlinked extra path) and a stub-`docker` run whose fake gateway writes a chained log with the real addon: log in the state dir, 0700/0444, head printed and `--verify` passes.
- **Bug caught.** A double-dash slug (`basename`'s newline through `tr -c`) was caught by inspecting the output; the test pattern is tightened.
- **Not live-verified** (no Docker).

Host smoke checklist handed to the user (exact commands, run from the repo root on the Docker host):
```bash
# 0. prerequisites (the addon is bind-mounted, so no image rebuild is needed if trigon-audit-gw:latest exists)
docker image inspect trigon-audit-gw:latest >/dev/null || ./build.sh --audit-gateway

# 1. --audit + --root / uid 0 refused (exit 1, nothing started)
./trigon-up.sh ~/test_proj --audit --root; echo "exit=$?"
sudo CLAUDE_SETTINGS_DIR=/tmp/trigon-smoke/root-settings ./trigon-up.sh ~/test_proj --audit; echo "exit=$?"   # scratch settings dir: the launcher creates it before the guard fires
docker ps -a --format '{{.Names}}' | grep audit-gw || echo "no gateway started"

# 2. two concurrent --audit sessions (run A and B in two terminals at the same time)
mkdir -p /tmp/trigon-smoke/a /tmp/trigon-smoke/b
printf 'Run `curl -sI https://example.com` and `curl -sI https://github.com` and report the status lines.\n' > /tmp/trigon-smoke/prompt.md
#   terminal A:
CLAUDE_SETTINGS_DIR=~/.trigon-settings-trigon-claude-code ./trigon-up.sh /tmp/trigon-smoke/a --name smoke-a --audit --yolo --prompt-file /tmp/trigon-smoke/prompt.md
#   terminal B:
CLAUDE_SETTINGS_DIR=~/.trigon-settings-trigon-claude-code ./trigon-up.sh /tmp/trigon-smoke/b --name smoke-b --audit --yolo --prompt-file /tmp/trigon-smoke/prompt.md
#   terminal C, while both run: two projects, two distinct gateways
docker compose ls | grep trigon-smoke
docker ps --format '{{.Names}}' | grep audit-gw
#   after both exit: nothing left behind
docker ps -a --format '{{.Names}}' | grep -E 'smoke|audit-gw' || echo "no containers left"
docker network ls --format '{{.Name}}' | grep trigon-smoke || echo "no networks left"

# 3. log in the new dir, read-only, chain verifies (use the head hash printed at the end of session A)
ls -la ~/.local/state/trigon/audit/ ~/.local/state/trigon/audit/a-*/
ls /tmp/trigon-smoke/a        # must NOT contain audit-log/
cat ~/.local/state/trigon/audit/a-*/summary-*.txt
python3 lib/audit_summary.py --verify ~/.local/state/trigon/audit/a-*/session-*.jsonl <HEAD_FROM_SESSION_A>
#   tamper demo on a copy: expect "BROKEN at line 2" (needs >= 2 records)
cp ~/.local/state/trigon/audit/a-*/session-*.jsonl /tmp/t.jsonl && chmod u+w /tmp/t.jsonl
sed -i '1s/"bytes_out":[0-9]*/"bytes_out":1/' /tmp/t.jsonl && python3 lib/audit_summary.py --verify /tmp/t.jsonl
#   truncation demo: chain alone passes, the recorded head catches it ("MISMATCH")
head -n -1 ~/.local/state/trigon/audit/a-*/session-*.jsonl > /tmp/t2.jsonl && python3 lib/audit_summary.py --verify /tmp/t2.jsonl <HEAD_FROM_SESSION_A>
#   deny-list: refused
./trigon-up.sh ~/.local/state/trigon/audit --dry-run; echo "exit=$?"
```
**Context**: CONSTRUCTION — Batch 1 complete (1a/1b/1c committed); next: host smoke run, then Batch 2.

---

## Construction — Batch 1 smoke checklist turned into a script
**Timestamp**: 2026-11-01
**User Input**: "Ok, I am a bit daunted by the smoke checklist .. and sometimes the commands seem to break into multiple lines, making it hard to see what I am meant to be running .. Some kind of output that makes explicit what is the same line .. and what I am meant to run and why .. would be good. also can I run all this while this trigon, the one we are currently in, is up ?"
**AI Response**: Replaced the copy-paste checklist with `tests/smoke/audit-batch1.sh`: one command, each step prints its "why" and PASS/FAIL, a final tally. It covers the `--root` refusal, an optional sudo uid-0 refusal (asked first), two concurrent `--audit --prompt-file` sessions (smoke-a/smoke-b) with both gateways seen running side by side, nothing left behind, logs in the state dir with 0700/0444 and no project `audit-log/`, chain verified against the printed head, edit and truncation detected on copies, and the deny-list refusal. The script uses its own settings dir (`~/.trigon-settings-smoke`, one-time `/login`) so the smoke sessions can't refresh or invalidate the OAuth token of the running session. Answered the concurrency question: yes. The running session (`trigon-dev`, launched before 1b, so compose project `compose`) shares no container name, project, network or settings dir with the smoke sessions, and the script only removes what it created. Shellcheck clean. Ran the script here against a simulated `docker` (17 pass, 1 skip); a stub bug (it took `claude -p`'s prompt for the project name) was found and fixed in the stub, not the script. Also removed an empty stray `/settings/.trigon-settings-My Box.1` that a manual dry-run in the previous session had created in the live settings dir. Real-Docker behaviour is still unverified. Not committed yet.
**Context**: CONSTRUCTION — Batch 1 awaiting host smoke run.

---

## Construction — Batch 1 smoke run: one-time login question
**Timestamp**: 2026-11-01
**User Input**: "Ok I did this: [pasted script output: preflight PASS for docker + image, FAIL 'no login for the smoke sessions yet' with the suggested `CLAUDE_SETTINGS_DIR=/home/bergurth/.trigon-settings-smoke /home/bergurth/projects/Trigon/trigon-up.sh /tmp/trigon-smoke/a --name smoke-login` command]

Am I meant to do this that it is asking me to do ?
run this ?
CLAUDE_SETTINGS_DIR=/home/bergurth/.trigon-settings-smoke /home/bergurth/projects/Trigon/trigon-up.sh /tmp/trigon-smoke/a --name smoke-login
in one line ?
then do the login ?"
**AI Response**: Confirmed: run it as one line from the repo root (gave the shorter `~/` / `./` form). It starts an interactive session with an empty, separate settings dir; do `/login`, then `/exit`, then re-run `./tests/smoke/audit-batch1.sh`. The login is one-time. Asked the user to paste the full output.
**Context**: CONSTRUCTION — Batch 1 host smoke run in progress.

---

## Construction — Batch 1 smoke run: root-owned /tmp/trigon-smoke
**Timestamp**: 2026-11-01
**User Input**: "Ok I ran it .. it seems to be still runing, prompting me for a y/n: [pasted output: preflight PASS (docker, image, smoke login); hundreds of `rm: cannot remove '/tmp/trigon-smoke/...': Permission denied` lines, incl. /tmp/trigon-smoke/a, /b and a full Claude Code settings tree under /tmp/trigon-smoke/root-settings (.claude.json, .claude/.credentials.json, sessions, npm/_npx playwright, mcp-logs dated 2026-11-01T00:20); `line 62: /tmp/trigon-smoke/prompt.md: Permission denied`; 1a `FAIL expected exit 1 + refusal, got exit 1` with `mkdir: cannot create directory '/tmp/trigon-smoke/settings-root': Permission denied`; then the sudo y/N prompt]

What should I do ? Say yes ? no ?"
**AI Response**: Told the user to Ctrl-C (the run is invalid). The 1a FAIL is an artifact: the launcher died creating its settings dir under the root-owned `/tmp/trigon-smoke` before reaching the guard. Flagged that `/tmp/trigon-smoke/root-settings` holds a complete session that ran as root (login + session files, ~00:19–00:20 UTC), which the script cannot have created. It most likely came from the `sudo CLAUDE_SETTINGS_DIR=/tmp/trigon-smoke/root-settings …` line of the earlier manual checklist; if that line included `--audit`, the uid-0 guard has a hole. Asked for `history | grep trigon-up | tail -20` to establish that, then `sudo rm -rf /tmp/trigon-smoke` (removes a root-owned login token), then a re-run answering y to the sudo check. Changed the script to stop with a one-line `sudo rm -rf` instruction when it cannot clear `$WORK`, instead of streaming rm errors. Open question pending the user's history: did a `sudo … --audit` launch start a session?
**Context**: CONSTRUCTION — Batch 1 smoke run; investigating a root-run session.

---

## Construction — Batch 1 smoke run: 18/18 PASS (live-verified)
**Timestamp**: 2026-11-01
**User Input**: [pasted `history | grep trigon-up | tail -20`: past project launches plus `2004 CLAUDE_SETTINGS_DIR=~/.trigon-settings-smoke ./trigon-up.sh /tmp/trigon-smoke/a --name smoke-login`, no sudo launch] [pasted `sudo rm -rf /tmp/trigon-smoke`] [pasted full script run: preflight PASS; 1a PASS refused; 1b sudo `y` → PASS refused (exit 1); 2 PASS gateways `trigon-smoke-a-4e9303-audit-gw-1` and `trigon-smoke-b-ef66d6-audit-gw-1` side by side, compose ls shows 2 projects, exit codes 0/0; 2b PASS no containers/networks left; 3 PASS no audit-log/ in either project, log at `/home/bergurth/.local/state/trigon/audit/a-3755779931/session-trigon-smoke-a-4e9303-20261101T004754Z.jsonl`, dir 0700, file 0444, smoke-b has its own log; 3b PASS `verified — 25 records, head sha256:3d220a19178af75f7837ca209536813316a7af1935970eb1ad4c4579bfea0119`; 3c PASS edit → `BROKEN at line 2`, truncation → `MISMATCH`; 3d PASS mount refused; Result: 18 passed, 0 failed, 0 skipped]

"Does this look good ? Everything checking out ?"
**AI Response**: Yes: Batch 1 (1a/1b/1c) is live-verified. The origin of the root-owned `root-settings` session is still unexplained: there is no `sudo trigon-up` in this shell's history, so it is possibly another terminal. Suggested `sudo journalctl _COMM=sudo --since today | grep -i trigon` to settle it. The guard itself is now proven by a sudo run from the user's account, and the leftover root token is deleted. Suggested checking the summary for example.com/github.com/api.anthropic.com. Reminded that DNS and non-80/443 egress remain unlogged until Batches 2–3. Updated aidlc-state (Batch 1 live-verified, next Batch 2) and session-start.
**Context**: CONSTRUCTION — Batch 1 complete and live-verified; next: Batch 2.

---
