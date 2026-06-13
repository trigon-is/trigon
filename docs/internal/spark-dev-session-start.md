# Spark DGX Integration — Session Start

**Last updated:** 2026-06-08  
**Stage:** SP0 complete → ready for SP1

---

## What we know about the Sparks

Three DGX Spark units on academic VPN. Only spark2 tested so far.

| Machine | IP | Status |
|---------|-----|--------|
| spark2 | 10.30.30.12 | ✅ Confirmed working — use this one |
| spark1 | unknown | Not yet tested |
| spark3 | unknown | Not yet tested |

### spark2 confirmed state

- **Ollama** running at `127.0.0.1:11434` (loopback only — no external access)
- **OpenAI-compat endpoint** at `http://localhost:11434/v1` — confirmed working
- **No Open WebUI, no NIM** — Ollama only
- **No Docker/sudo access** for `bergurth` user account
- **Models installed:**

| Model | Size | Notes |
|-------|------|-------|
| `foundationsec-q4-reasoning:latest` | 4.9 GB | **Recommended** — fast, reasoning tuned |
| `foundationsec-reasoning-q8:latest` | 8.5 GB | Better quality, still fast |
| `foundationsec-8b:latest` | 16 GB | Full FP16 |
| `foundationsec-q4:latest` | 4.9 GB | No reasoning tuning |
| `FenkoHQ/Foundation-Sec-8B:latest` | 16 GB | Alternate source, same model |

Inference smoke test passed: `foundationsec-q4-reasoning` responded correctly to CVE-2021-44228 query.

---

## The access problem and its fix

Ollama is loopback-only. Docker containers on your host cannot reach `10.30.30.12:11434` directly.

**Fix: SSH port forward (no sudo required)**

```bash
# Run this on your HOST before starting Trigon — keep it open in a terminal
ssh -N -L 0.0.0.0:11435:localhost:11434 bergurth@10.30.30.12
```

This maps `0.0.0.0:11435` on your host → `localhost:11434` on spark2.  
Binding to `0.0.0.0` (not `127.0.0.1`) is required so Docker containers can reach it via the bridge IP.  
LiteLLM in Docker then reaches it via `host.docker.internal:11435`.

**Note:** port 11434 is typically occupied by local Ollama. Use 11435 for the spark tunnel.

**Verify the tunnel works from your host:**
```bash
curl -s http://localhost:11434/v1/models | python3 -m json.tool | grep '"id"'
```

**SP0 gate test — confirm Docker containers can reach it:**
```bash
docker run --rm curlimages/curl:latest curl -s http://host.docker.internal:11434/v1/models
```

If that returns model IDs, SP0 is complete and you can proceed to SP1.

---

## SP1 — What to implement next

Create `providers/spark-foundationsec.yml` in the Trigon repo at `/app_4`:

```yaml
type: litellm-proxy
litellm_model_prefix: "ollama/"
litellm_api_base: "http://host.docker.internal:11434"
default_model: foundationsec-q4-reasoning:latest
model_map:
  default: foundationsec-q4-reasoning:latest
  quality: foundationsec-reasoning-q8:latest
  full: foundationsec-8b:latest
api_key_env: SPARK_API_KEY
requires: []
notes: >
  Requires SSH tunnel active on host before launching:
  ssh -N -L 11434:localhost:11434 bergurth@10.30.30.12
  No API key needed for Ollama — set SPARK_API_KEY to any non-empty string.
```

**SP1 launch test:**
```bash
export SPARK_API_KEY=dummy
./trigon-up.sh ~/test-project --mode security --provider spark-foundationsec --api
```

**SP1 gate:** LiteLLM sidecar healthy; inference call returns a response from FoundationSec.

---

## SP2 — Prompt-file pipeline

Once SP1 passes, test with a real security prompt:

```bash
export SPARK_API_KEY=dummy
./trigon-up.sh ~/pentest-project \
  --mode security \
  --provider spark-foundationsec \
  --prompt-file prompts/cve-triage.md \
  --api
```

---

## Spark SSH diagnostic cheatsheet

```bash
# SSH in
ssh bergurth@10.30.30.12

# Confirm Ollama is up and models loaded
ollama list

# Confirm OpenAI-compat endpoint
curl -s http://localhost:11434/v1/models | python3 -m json.tool | grep '"id"'

# Quick inference test
curl -s http://localhost:11434/api/generate \
  -d '{"model":"foundationsec-q4-reasoning:latest","prompt":"What is CVE-2021-44228?","stream":false}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response','')[:500])"

# GPU status
nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv
```

---

## Outstanding items

- [ ] SP0 gate: confirm Docker → `host.docker.internal:11434` works through SSH tunnel
- [ ] SP1: create `providers/spark-foundationsec.yml` and test LiteLLM → Ollama path
- [ ] SP2: run `--prompt-file` pipeline against FoundationSec reasoning model
- [ ] Investigate spark1 and spark3 IPs (ask institution or check ARP table on spark2: `arp -n`)
- [ ] SP4 (future): multi-node `providers/spark-cluster.yml` once all three IPs known
