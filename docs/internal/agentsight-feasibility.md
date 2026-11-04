# AgentSight + Trigon — Feasibility Exploration

**Date:** 2026-11-04
**Status:** exploration, nothing decided. Facts about AgentSight come from its paper and
GitHub docs (sources at the end), not from running it. Items marked *(verify)* are
inferences or doc gaps that the spike in §7 has to check.

**Question.** Should Trigon integrate AgentSight (or a similar eBPF observer)? And would
that be a better use of effort than growing the `--audit` feature further, leaving Trigon
leaner? This note sets out what each tool does, where they overlap, and how to decide.

---

## 1. What AgentSight is

An open-source observer for AI agents. Paper: Zheng, Hu, Yu, Quinn, *AgentSight:
System-Level Observability for AI Agents Using eBPF*, PACMI 2025 (UC Santa Cruz,
ShanghaiTech, eunomia-bpf community). Repo `eunomia-bpf/agentsight`, MIT licence, Rust
with C eBPF probes, ~770 stars, crate version 0.2.x (young and changing fast).

It does "boundary tracing" from the host kernel, without modifying the agent:

- **Intent side.** uprobes on the TLS library (`SSL_write`/`SSL_read`) read LLM traffic
  as plaintext before encryption and after decryption. It handles system OpenSSL, Node's
  bundled OpenSSL and the statically linked BoringSSL in Claude Code/Bun binaries, using
  `--binary-path` or auto-discovery.
- **Effect side.** Kernel events: process exec, file opens (incl. `openat2`, io_uring),
  and network activity (`--trace-net`).
- **Correlation.** It links prompts and tool calls to the processes and files they cause,
  with an optional second LLM doing the analysis.
- **Output.** SQLite session DB, JSON export, web UI (`127.0.0.1:7395`), OpenTelemetry
  GenAI spans over OTLP. Overhead under 3% CPU in their evaluation.
- **Requirements.** Linux 5.0+ recommended. Root or `CAP_BPF`/`CAP_SYS_ADMIN`. Running it
  in Docker needs `--privileged --pid=host` and host mounts of `/sys`, `/usr`, `/lib`.

**What it is not.** It only observes: no blocking, no isolation, no egress control. It is
not a harness, because it doesn't launch or contain the agent. Its threat model is
observability and prompt-injection detection, not an adversarial agent trying to evade it.

## 2. Where the two overlap and where they differ

| | Trigon `--audit` (gateway) | AgentSight (eBPF on the host) |
|---|---|---|
| Containment, egress enforcement | **Yes**: agent on an internal net, gateway is the only route | None |
| Destinations | Complete by construction, hostile agent included | Every `connect()` of traced processes. Complete only if attribution is complete *(verify)* |
| Content of LLM traffic | Only with `--audit-decrypt` (MITM with a session CA). Pinned flows stay opaque. **No bodies logged today** | Plaintext from the TLS hooks, no CA. Pinning doesn't matter. Bodies logged |
| Local effects (files, exec) | None | **Yes** |
| Tamper-evidence | Log outside every agent mount, sha256 chain, head printed | DB written by a host process, outside the agent's reach, but not chained |
| Privileges | Unprivileged launcher. `--audit` refuses uid 0. `NET_ADMIN` only in the sidecar | Root / privileged container with host PID namespace |
| Platforms | Linux; macOS partly | Linux only for capture |
| Default privacy | Destination-only (minimal PII) | Captures everything, prompts included; redaction not documented *(verify)* |

**What both share.** Each gives a *hard* guarantee about where traffic goes and a *soft*,
cooperative one about what it says:
- Trigon's decryption fails on pinned flows.
- AgentSight's TLS hooks fail on any crypto they don't know: an agent bringing its own TLS
  or encrypting before sending shows up only as a `connect()` *(inference from how uprobes
  work; verify)*.

So neither tool alone makes content capture unbypassable. This matters for the thesis
(LA1: the covert room is in the content).

## 3. Benefits an integration could bring

1. **Content without a man-in-the-middle.** No CA injected into the agent and no mitmproxy
   TLS termination. Pinning stops being a problem. This replaces the soft half of
   `--audit-decrypt` with a more robust mechanism.
2. **Tool-call logging comes ready-made.** The 11-03 idea ("log parsed tool calls from
   provider traffic") is roughly what AgentSight already records. Trigon wouldn't need to
   write a body parser per provider format (Anthropic, OpenAI via LiteLLM, ...).
3. **A new axis: local effects.** Trigon sees nothing of what the agent does inside its
   mounts (reading credentials that were mounted by mistake, rewriting `.git/hooks`,
   editing its own settings or transcripts). AgentSight sees file opens and execs.
4. **Ecosystem.** OTEL export puts sessions into existing observability stacks.
5. **Less Trigon code** if it replaces planned work rather than adding to it (§5).
6. **For the thesis.** Real Claude Code tool-call samples, collected without modifying the
   agent, are the LA1 hosted-model data. Its LLM analyser is close to LA2.

## 4. How it could be wired in

**Shape A — host process, launched by `trigon-up.sh`** (simplest):
`--observe` starts `sudo agentsight record …` before `compose up`, attached to the agent
container's processes, and stops it in `cleanup`. The DB goes to
`~/.local/state/trigon/observe/<project>/` next to the audit logs. At session end its
sha256 joins the audit chain (or its own chain via `lib/audit_summary.py`).
- Problem: Trigon becomes a launcher that calls `sudo`. That conflicts with the "launch as
  an unprivileged user" stance and with the uid-0 refusal for `--audit`. Alternative: the
  user starts AgentSight themselves and Trigon just prints the command / container PID.

**Shape B — privileged sidecar `observe`** (`privileged: true`, `pid: host`, read-only
host mounts): Compose-native, so it is started and torn down with the session. It shares
no network or PID namespace with the agent, so the agent can't reach it *(verify the web
UI on host loopback is unreachable from the agent net)*. Problem: a privileged container
in the stack is effectively root on the host. That is a large trust addition, though
in a component the agent never touches.

**Shape C — no integration, documented recipe:** a `docs/observe.md` explaining how to run
AgentSight next to a Trigon session. Zero code, zero privilege added to Trigon.

**Open technical questions (all for the spike):**
- **Attribution.** Can AgentSight be limited to *one container's* processes and all their
  descendants (cgroup ID), or only by `--comm`/binary path? The docs don't say how to
  filter per container. Two concurrent Trigon sessions make this matter.
- **Binary inside the overlay.** The Claude Code binary lives in the container's overlay
  filesystem. Does `--binary-path /proc/<pid>/root/...` work for the uprobes? Trigon
  installs Claude Code with `npm install -g` (Node or the native binary, depending on
  version, *verify*) and OpenCode as a Bun binary (BoringSSL).
- **Version churn.** Claude Code is un-pegged (`latest`). Does symbol discovery for
  statically linked BoringSSL survive every update? Pin both tools for the integration.
- **Interplay with `--audit-decrypt`.** The hooks read plaintext *inside* the agent before
  it reaches the gateway, so MITM shouldn't confuse them. Check that both logs agree on
  destinations.
- **Secrets.** Does the DB contain the API key / OAuth token from request headers?
  Redaction is undocumented.

## 5. The "leaner Trigon" question

Remaining or planned audit work, and whether AgentSight could replace it:

| Work item | What it gives | Replaceable by AgentSight? |
|---|---|---|
| Batch 2: all-TCP redirect, REJECT the rest, IPv6 off | "All egress logged *or blocked*": enforcement | **No.** AgentSight doesn't block. Keep it; it is small and half-designed |
| Batch 3: DNS logging | Closes an unlogged channel | Partly: it sees UDP sends with `--trace-net`, but not as a DNS log, and it doesn't block. Keep in Trigon |
| Batch 4: live gates, digest pin, tests, PR | Finishing what exists | No. Needed anyway |
| `--audit-decrypt` depth (method/path/status) | Soft content visibility | **Largely yes**, and more robustly (no CA, pinning irrelevant) |
| Tool-call logging (11-03 idea) | Arguments of tool calls: the thesis-relevant channel | **Yes, probably.** Already AgentSight's core feature |
| G6 egress allow-list | Enforcement | No |
| Local-effects audit (not planned) | Files/exec | Only AgentSight provides it |

**Working hypothesis (to test, not a conclusion):** the split is between *enforcement* and
*observation*. Trigon finishes the enforced gateway (Batches 2–4, later G6), which is
small, close to done, and something no observer provides. It stops growing the
*content-observation* side: `--audit-decrypt` stays as is or is frozen, and tool-call
logging is not built in Trigon. Content and local effects are delegated to AgentSight
(Shape C first, then A or B if the spike goes well). The result: Trigon keeps the hard
guarantees, and the soft, feature-rich part comes from a maintained open-source tool.

**What would falsify it:**
- Attribution to one container is unreliable or needs fragile per-version tweaks.
- Claude Code / OpenCode inside a container can't be hooked without hand-tuned paths.
- The tool is too unstable to pin (breaking changes between 0.2.x releases).
- Secrets end up in the DB with no way to redact them.
- The privilege cost (root / privileged sidecar) is unacceptable for the target users
  (JSP pipeline, cloud VMs).

In those cases, tool-call logging stays a Trigon feature on top of the existing mitmproxy
addon (secrets design first).

## 6. Runtimes: runc, gVisor, Kata/microVM

**Background.** A Docker container is a host process fenced by namespaces and cgroups. It
shares the host kernel, so a kernel bug can be an escape (threat model #4). Docker lets
you swap the low-level runtime with no change to images or Compose (`runtime:` key):

| Runtime | How it isolates | Kernel the agent talks to | Cost |
|---|---|---|---|
| `runc` (default) | Namespaces + cgroups | The host kernel | ~none |
| gVisor (`runsc`) | A user-space kernel (the Sentry) handles the agent's syscalls | gVisor's | Syscall-heavy work slower, some compatibility gaps. No KVM needed |
| Kata Containers | Each container in a small VM (KVM via QEMU, Cloud Hypervisor or Firecracker) | Its own guest kernel | More memory, slower start. Needs KVM (nested virtualization on cloud VMs) |

**Rule for placing the observer:** it must sit where it can see the agent and the agent
can't reach it. Each runtime moves that place.

- **runc.** Host eBPF sees everything. This is the case §1–5 assume.
- **gVisor.** Host eBPF mostly sees the Sentry, not the agent. Whether TLS uprobes still
  fire is unclear *(verify)*. gVisor's own runtime monitoring streams syscall events to an
  external collector (Falco uses it), which covers the effects side but not plaintext.
  This is the worst fit for AgentSight.
- **Kata / microVM.** From the host the VM is a black box (VM introspection exists but is
  research-grade). **Inside the guest kernel AgentSight works unchanged**, because it is an
  ordinary Linux kernel. See §6a.
- **macOS / Docker Desktop.** Containers already run in a Linux VM. That is the same
  "observer inside the VM" situation, untested.

**The gateway doesn't depend on the runtime.** It works at the network level. A Kata VM's
traffic still leaves through one virtual network card into the host network, so `--audit`
enforcement and the destination log work the same under all three runtimes. A microVM
gives an even cleaner choke point (one virtual NIC, no shared kernel networking).

**Trigon's privacy default.** `--audit` was designed destination-only on purpose
(compliance artifact, minimal PII). Full capture has to stay a separate, loud opt-in on
every runtime.

## 6a. Goal direction: containment and observability together (microVM)

**Status: adopted as a long-term goal (2026-11-04). Not scheduled; depends on the spike
(§7) and a Kata/Firecracker trial.**

The target architecture has three layers, each with a different trust position:

```
 host (trusted)
 ├── audit gateway ............ enforcement + destination log   (outside the VM; hard)
 ├── chained log store ........ receives the streamed events    (outside the VM)
 └── microVM (Kata / Firecracker)
      ├── guest kernel + observer (AgentSight, root in the guest only)
      │      └── streams events out over vsock ──► chained log store
      └── agent (unprivileged in the guest)
```

**Why it is attractive:**
1. **Containment.** Hardware virtualization boundary: a guest-kernel bug doesn't reach the
   host. This closes threat-model #4 (the open "gVisor / Kata" question in §6–7 there).
2. **No host privilege for observation.** The observer needs root only inside a
   disposable VM. No `sudo` from the launcher, no privileged sidecar on the host. This
   removes the main difficulty in §4 (Shapes A and B).
3. **The enforcement/observation split stays clean.** The gateway (hard guarantee) is
   outside the VM and runtime-independent. The observer (soft, rich layer) is inside,
   where the kernel is.
4. **The guest is ours.** Kata lets you customise the guest kernel and rootfs, so the
   observer and its pinned version can be baked into the guest image. That also fixes the
   kernel version AgentSight runs against (fewer surprises than arbitrary host kernels).

**The price, and how to pay it:**
- **The observer sits inside the agent's isolation boundary.** If the agent gets root in
  the guest (easier than a VM escape), it can tamper with the observer. Mitigation:
  stream every event out *as it happens* (vsock or the network) into the host-side
  hash-chained store. A compromised guest can then stop new records or forge future ones,
  but can't change past ones, and the chain shows where the gap starts. Keep the agent
  unprivileged in the guest (`cap_drop: ALL`, `no-new-privileges`, as today).
- **Operations.** KVM access is needed. Cloud VMs need nested virtualization, or bare
  metal / instances that allow it. Kata runs through containerd. Check how cleanly it works
  from Docker Compose versus containerd/nerdctl *(verify)*. Firecracker alone has no
  Docker integration; it would go through Kata or a dedicated launcher.
- **Startup and memory.** ~100 ms–1 s extra start time and a per-VM memory overhead.
  This is fine for interactive sessions; it matters for pipeline fan-out.
- **Playwright, `ipc: host`, `network_mode` tricks.** Fragments that rely on sharing host
  namespaces won't carry over to a VM unchanged. The `--audit` design shares the gateway's
  network namespace with the agent (`network_mode: "service:audit-gw"`), so under Kata it
  needs rethinking (gateway on the VM's network path instead) *(verify)*.

**How it fits Trigon's shape.** A fourth axis, `--runtime runc|gvisor|kata`, next to
provider, agent and mode. Each runtime needs its own `--observe` recipe (host eBPF; gVisor
monitoring; in-guest AgentSight + vsock stream). The gateway needs none.

**Steps toward it (rough order):**
1. The runc spike (§7, steps 1–8): does AgentSight do the job at all?
2. Kata trial without observation: does a plain Trigon session (Claude Code, `--audit`)
   run under the Kata runtime? Note what breaks (network namespace sharing, Playwright).
3. In-guest AgentSight: bake it into a guest image, capture one session, stream events
   out over vsock to a host collector, chain them with `lib/audit_summary.py`.
4. Tamper test: get root in the guest, kill or modify the observer, and confirm the host
   log shows the gap and older records still verify.

## 7. Spike plan (on the Docker host; this dev container has no capabilities for eBPF)

About half a day. Pin an AgentSight release. For each step, record PASS/FAIL and notes.

1. **Baseline on the host.** `sudo agentsight record -- claude -p "…"` with one tool
   call. Are the prompt, response and tool call (with arguments) in the DB?
2. **Into a Trigon container** (no `--audit`). Run the observer on the host, target the
   agent container's Claude Code. Are binary discovery, per-container attribution and
   child processes (a Bash tool call running `curl`) all captured?
3. **With `--audit --audit-decrypt`.** Do the two destination lists agree? Is plaintext
   still captured under MITM?
4. **OpenCode** (Bun / BoringSSL) in its Trigon image.
5. **Evasion check** (soft guarantee). From inside the container, send HTTPS with
   (a) `curl` (system libssl), (b) Python `ssl`, (c) a statically linked Go binary.
   Which give plaintext, which only a `connect()`?
6. **Two concurrent sessions.** Are their events kept apart?
7. **Secrets.** grep the DB and the JSON export for the API key / OAuth token.
8. **Overhead and stability.** One longer session; does anything crash or get dropped?

9. **(Later, separate trial) microVM.** Steps 2–4 of §6a.

**Decision rule.** If 1–4 and 6 pass and 7 is solvable, adopt the hypothesis in §5:
ship Shape C (docs) now, consider A/B later, and drop tool-call logging from Trigon's
plan. If 2 or 6 fail, keep tool-call logging in Trigon and cite AgentSight as related work.

## 8. Similar tools (for the harness survey, "observers" category)

- **AgentSight**: the only agent-specific one; LLM plaintext + system effects.
- **Tetragon** (Cilium): eBPF observation **and** enforcement (kill/deny by policy), not
  LLM-aware. Interesting if Trigon ever wants kernel-level enforcement.
- **Falco**, **Tracee**: eBPF runtime security detection; rules, no TLS plaintext.

These are observers or enforcers at the kernel level, not harnesses. They sit next to
harnesses in the survey.

## Sources

- Paper: https://arxiv.org/abs/2508.02736
- Repo: https://github.com/eunomia-bpf/agentsight (README, `docs/docker.md`, `docs/usage.md`)
- Trigon: `docs/audit-design.md`, `docs/audit/aidlc-state.md` (completion plan),
  `docs/threat-model.md` §6–7, `docs/session-start.md` (ideas 2026-11-03)
