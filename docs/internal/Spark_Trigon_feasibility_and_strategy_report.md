# Spark DGX + Trigon Security Mode — Feasibility & Strategy Report

**Date:** 2026-06-08  
**Status:** Pre-spike planning  
**Context:** Academic VPN access to three NVIDIA DGX Spark units; target model: Cisco FoundationSec 8B; target use-case: Trigon `--mode security` against a remote GPU-backed inference endpoint.

---

## 1. Hardware Overview

### NVIDIA DGX Spark (GB10 Grace Blackwell)
The DGX Spark is a compact AI workstation built on the GB10 Grace Blackwell Superchip:

| Spec | Value |
|------|-------|
| AI compute | ~1 PFLOP (FP8) |
| GPU | Blackwell GPU (72 Tensor Cores) |
| Unified memory | 128 GB (CPU + GPU shared) |
| Memory bandwidth | ~273 GB/s |
| Form factor | Desktop / rackmount |

Three units gives approximately 3 PFLOP aggregate. At 128 GB unified memory per node, each can run models up to ~70B parameters comfortably in FP16, or ~100B+ in 4-bit quantisation.

### Cisco FoundationSec 8B
A security-domain LLM released by Cisco in 2025, based on Llama 3 8B, fine-tuned on:
- CVE descriptions and advisories
- Malware analysis reports
- Threat intelligence (MITRE ATT&CK, STIX/TAXII)
- Penetration testing methodologies
- Network protocol and vulnerability reasoning

It is specifically designed for **security reasoning tasks**: CVE triage, threat classification, attack path analysis, report generation. It is NOT a general coding agent and has limited tool-calling training.

---

## 2. Assumed Serving Architecture

The Spark DGX units likely expose one of these API surfaces (to be confirmed with the academic institution):

| Backend | Port | API Format | Notes |
|---------|------|-----------|-------|
| **Open WebUI** | 3000 | OpenAI-compatible at `/api` | Most likely for academic setup; web UI included |
| **Ollama** | 11434 | Ollama native (OpenAI-compat at `/api`) | Simple, pull-and-serve |
| **NVIDIA NIM** | 8000 | OpenAI-compatible | Production inference microservice |
| **vLLM** | 8000 | OpenAI-compatible | High-throughput, common in academic clusters |

All four expose an **OpenAI-compatible** API. LiteLLM can proxy all of them. The integration path into Trigon is the same regardless of which backend is running.

---

## 3. How Trigon Connects

### Network path

```
Host machine
  └── VPN tun0 interface  ←  WireGuard / OpenVPN to academic network
        └── Spark DGX VPN IP (e.g. 10.x.x.y:3000)
              └── Open WebUI / Ollama / NIM serving FoundationSec 8B
```

```
Trigon container (Claude Code agent)
  └── ANTHROPIC_BASE_URL=http://litellm:4000
        └── LiteLLM sidecar container
              └── HTTP → host VPN routing → Spark DGX API
```

The LiteLLM sidecar uses Docker bridge networking. Its outbound traffic goes through the host's routing table. As long as the VPN is active on the host and the VPN routes the Spark DGX subnet, LiteLLM can reach it — **no changes to Trigon's networking code are needed**.

### Provider YAML

A new provider file `providers/spark-foundationsec.yml`:

```yaml
type: litellm-proxy
# Open WebUI exposes OpenAI-compatible API at /api
litellm_model_prefix: "openai/"
litellm_api_base: "http://SPARK_VPN_IP:3000/api"
default_model: cisco/foundation-sec-8b
model_map:
  default: cisco/foundation-sec-8b
api_key_env: SPARK_API_KEY
requires:
  - SPARK_API_KEY
notes: >
  Requires VPN active on host before launching.
  Set SPARK_VPN_IP in your environment or update litellm_api_base.
  API key is the Open WebUI user token (Settings → Account → API Keys).
```

Usage:
```bash
export SPARK_API_KEY=<open-webui-token>
./trigon-up.sh ~/pentest-project --mode security --provider spark-foundationsec --yolo
```

---

## 4. Feasibility Assessment

### What will work well

| Capability | Assessment |
|------------|-----------|
| Network routing (VPN → LiteLLM → Spark) | ✅ Standard Docker bridge routing |
| Provider YAML + LiteLLM proxy | ✅ OpenAI-compat; existing tier-2 path |
| Inference speed | ✅ Blackwell GPU; 8B model ≈ fast token generation |
| Security domain reasoning | ✅ FoundationSec is purpose-built for this |
| Report generation, CVE triage, threat analysis | ✅ Core FoundationSec strengths |
| `--mode security` context injection | ✅ Works unchanged |
| `drop_params: true` for unsupported params | ✅ Already implemented |

### What will not work / known problems

| Problem | Severity | Notes |
|---------|----------|-------|
| **Claude Code tool calling** | ⚠ High | FoundationSec 8B is not trained on Claude Code's Anthropic-format tool schema. Expect same chat-only behaviour seen with qwen2.5-coder:7b. Read/write/bash tool calls will likely fail or be ignored. |
| **VPN prerequisite** | ⚠ Medium | Trigon has no VPN lifecycle management. VPN must be connected on the host *before* launch. No automatic detection or error on failure. |
| **Dynamic VPN IP** | ⚠ Medium | `litellm_api_base` is static in the YAML. If the Spark DGX's VPN IP changes, the YAML needs updating or an env var override is needed. |
| **Docker VPN routing edge cases** | ⚠ Medium | Some VPN clients (Cisco AnyConnect, certain split-tunnel configs) do not route Docker bridge traffic through the VPN tunnel. Requires testing. |
| **Open WebUI auth** | Low | Needs a per-user API key from the Open WebUI interface. Key rotation is manual. |
| **Multi-node load balancing** | Low | Three Spark DGXs are available but LiteLLM will only target one at a time per config. Round-robin across nodes needs explicit LiteLLM `model_list` expansion. |

---

## 5. The Tool-Calling Problem — Central Challenge

The core issue from M3 Ollama testing applies here too: **Claude Code relies on Anthropic-format tool calls**. LiteLLM translates these to OpenAI format, but 8B models fine-tuned for domain reasoning (not agentic tool use) typically ignore or misformat tool call responses, falling back to chat output.

**This means the Claude Code harness will not function as an agent against FoundationSec 8B.** It will respond as a chat model — useful for interactive Q&A but unable to run bash commands, read files autonomously, or chain multi-step tool calls.

### Two viable approaches given this constraint

**Option A — Prompt-file pipeline mode (works now)**  
Use `--prompt-file` to send structured security prompts to FoundationSec 8B and collect its text output. No tool calling required. The model produces analysis; a human or outer script acts on it.

```bash
./trigon-up.sh ~/pentest-project \
  --mode security \
  --provider spark-foundationsec \
  --prompt-file prompts/cve-triage.md \
  --api
```

Suitable for: CVE summarisation, threat report generation, attack surface analysis from text input.

**Option B — OpenCode agent (M5, the right long-term path)**  
OpenCode natively supports OpenAI-compatible providers with proper tool-call format mapping. Running OpenCode against FoundationSec 8B on Spark DGX would give genuine agentic behaviour: read files, run nmap, chain commands.

This is the architecturally correct solution. FoundationSec 8B + OpenCode + Spark DGX is a compelling security agent stack.

---

## 6. Docker VPN Routing — Detailed Analysis

This is the most uncertain technical area and requires hands-on testing.

### Scenario 1 — WireGuard / standard OpenVPN (likely to work)
These VPN clients add a route for the remote subnet via `tun0`. Docker bridge containers route outbound traffic through the host kernel's forwarding rules. If `net.ipv4.ip_forward=1` (default on Docker hosts), containers can reach VPN-routed IPs.

**Test:** with VPN active, from the host:
```bash
docker run --rm curlimages/curl curl http://<SPARK_VPN_IP>:3000/api/version
```
If this returns an Open WebUI response, routing works.

### Scenario 2 — Split-tunnel with Docker exclusion
Some enterprise/academic VPN configs explicitly exclude Docker bridge subnets (`172.16.0.0/12`) from the VPN tunnel. Symptoms: host can reach Spark DGX, but Docker containers cannot.

**Fix options:**
1. Add Docker bridge subnet to VPN split-tunnel include rules (requires institution cooperation)
2. Run LiteLLM with `network_mode: host` — it then uses the host's VPN interface directly
3. Pass the Spark DGX IP as an `extra_hosts` entry pointing through the VPN gateway

### Scenario 3 — Cisco AnyConnect / Pulse
These clients sometimes override routing tables in ways that block Docker traffic. Known issue with no clean fix without client-side configuration.

**Workaround:** Run a local port-forward on the host:
```bash
# On host: forward localhost:3000 → Spark DGX via SSH over VPN
ssh -L 3000:<SPARK_VPN_IP>:3000 user@<jump-host>
```
Then set `litellm_api_base: "http://host.docker.internal:3000/api"` — LiteLLM reaches the Spark DGX via the local SSH tunnel.

---

## 7. Multi-Node Strategy (Three Spark DGXs)

With three Spark DGXs, LiteLLM's native load balancing can distribute inference:

```yaml
# providers/spark-cluster.yml (future)
model_list:
  - model_name: foundation-sec-8b
    litellm_params:
      model: openai/cisco/foundation-sec-8b
      api_base: http://SPARK1_IP:3000/api
      api_key: ${SPARK_API_KEY}
  - model_name: foundation-sec-8b
    litellm_params:
      model: openai/cisco/foundation-sec-8b
      api_base: http://SPARK2_IP:3000/api
      api_key: ${SPARK_API_KEY}
  - model_name: foundation-sec-8b
    litellm_params:
      model: openai/cisco/foundation-sec-8b
      api_base: http://SPARK3_IP:3000/api
      api_key: ${SPARK_API_KEY}

litellm_settings:
  drop_params: true
  routing_strategy: least-busy
```

This gives throughput scaling for parallel pipeline runs and automatic failover if one node is busy or down.

---

## 8. Milestones

### SP0 — Connectivity spike (prerequisite, ~1 hour)
- Confirm Spark DGX API endpoint, port, and format with institution
- Test Docker container → Spark DGX connectivity with VPN active (see §6)
- Identify model name as registered in Open WebUI / Ollama

**Gate:** `docker run --rm curlimages/curl curl http://<SPARK_IP>:<PORT>/api/version` returns valid response.

---

### SP1 — Provider YAML + basic connection (~half day)
- Create `providers/spark-foundationsec.yml` with confirmed IP/port/model name
- Consider adding `SPARK_VPN_IP` as an env var override rather than hardcoding (cleaner for multi-user)
- Test: `./trigon-up.sh ~/test --provider spark-foundationsec --api` reaches LiteLLM healthcheck

**Gate:** LiteLLM sidecar healthy; inference call returns any response from FoundationSec 8B.

---

### SP2 — Prompt-file pipeline validation (~half day)
- Write a structured security prompt (CVE triage, threat analysis, or recon summary)
- Run `--prompt-file` against FoundationSec 8B on Spark DGX
- Evaluate output quality for security tasks

**Gate:** FoundationSec 8B produces coherent, domain-specific security analysis from `--prompt-file` input.

---

### SP3 — VPN env var and `--vpn-check` flag (optional, ~1 hour)
- Add optional `vpn_check_url` field to provider YAML
- If set, `trigon-up.sh` tests reachability before starting containers and errors early with a clear message if VPN is not active
- This avoids the 4-minute LiteLLM retry loop before failing

**Gate:** `./trigon-up.sh ... --provider spark-foundationsec` with VPN down prints `Error: VPN required — cannot reach SPARK_VPN_IP:3000` immediately.

---

### SP4 — Multi-node cluster config (optional, ~half day)
- Determine if all three Spark DGXs are independently accessible via VPN
- Create `providers/spark-cluster.yml` with LiteLLM `least-busy` routing
- Test parallel `--prompt-file` pipeline runs

**Gate:** Two simultaneous `trigon-up.sh --prompt-file` runs complete faster than sequential.

---

### SP5 — OpenCode + FoundationSec 8B (depends on M5)
Once OpenCode agent support lands (M5), revisit Spark DGX with OpenCode as the agent layer instead of Claude Code. OpenCode's native tool-call format mapping should enable genuine agentic security workflows:
- Autonomous `nmap`/`nuclei` runs
- File read/write for report generation
- Multi-step recon → analysis → report pipelines

**Gate:** OpenCode agent uses FoundationSec 8B on Spark DGX to complete a multi-step security task autonomously.

---

## 9. Security Considerations

Running a security-mode agent against remote academic hardware introduces some considerations:

- **Prompt confidentiality**: Target hostnames, CVEs, and pentest context in prompts leave the local machine and traverse the VPN to Spark DGX. Academic infrastructure logs may capture these. Confirm data handling policy with the institution before sending sensitive target data.
- **Output storage**: Reports written to the mounted project volume are local; nothing persists on the Spark DGX unless explicitly sent there.
- **API key scope**: Open WebUI API keys are per-user. Do not share keys between team members on shared academic access.
- **Rate limits / fair use**: Academic access may have usage quotas. The `--max-budget` flag is not directly applicable (budget tracking is API-billing specific), but pipeline prompt files should be scoped to avoid excessive token usage.

---

## 10. Summary Recommendation

| Question | Answer |
|----------|--------|
| Is the Trigon ↔ Spark DGX integration feasible? | ✅ Yes, via existing LiteLLM tier-2 path |
| Does it work today (without M5)? | ⚠ Partially — prompt-file mode only; no agentic tool use |
| Is FoundationSec 8B useful for security mode? | ✅ Yes, for reasoning/analysis tasks; not for autonomous tool execution |
| What's the critical unknown? | Docker VPN routing (§6) — must be tested before anything else |
| What's the right long-term stack? | OpenCode (M5) + FoundationSec 8B + Spark DGX cluster |

**Recommended first step:** Run the SP0 connectivity spike. Everything else depends on whether Docker containers can reach the Spark DGX API through the VPN — which takes 15 minutes to test and determines whether the entire stack is viable on this network.
