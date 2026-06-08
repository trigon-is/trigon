# Triquetra Use-Case Analysis
# Connecting the JobSearchPipeline to V3 SaaS Architecture

**Date:** 2026-06-02  
**Status:** Analysis / design exploration

---

## 1. What this document is

This document grounds Triquetra's abstract architecture in two concrete systems:

1. **JobSearchPipeline (JSP) V2** — a working multi-candidate pipeline in `/app_2`,
   using `claude-in-container` (`/app`) as its AI execution layer.
2. **JSP V3** — a planned multi-user SaaS product described in `/app_3`.

The goal is to answer: where does Triquetra fit, what does it unlock, and what would
a production-grade multi-pipeline architecture look like — including a Kubernetes option.

---

## 2. How JSP V2 uses Triquetra primitives today

The current pipeline (`/app_2/pipeline/run-pipeline.sh`) runs three stages per candidate:

| Stage | What runs | Current implementation |
|-------|-----------|------------------------|
| Scout | Web scraping + fit scoring | `claude-up.sh` with `--playwright --prompt-file scout.md` |
| Write | Cover letter generation | Direct Anthropic Python SDK call in `write_letters.py` |
| Track | YAML update | Pure Python, no AI |

The scout stage is already a Triquetra-style invocation in everything but name:
a stateless container run, a single prompt file, filesystem output
(`scout-output.json`), mounted volume (`candidates/{name}/`).

The letter-writing stage is *not* using the container harness — it calls the
Anthropic API directly in Python. This was the right call at V2 stage: simpler,
no container overhead. But it creates a split between the two AI stages that matters
more as we add providers.

### What Triquetra would change for V2

**Provider switching.** The scout stage is a commodity task: navigate pages,
extract structured data, apply scoring rules. It does not require the best model.
DeepSeek-chat runs it at roughly 1/10th the cost of Claude Sonnet. The letter
stage is the product's core value — prose quality matters, and paying for Sonnet
or Opus is justified.

```bash
# V2 pipeline with Triquetra provider split (not yet implemented)

# Scout: cheap model, Playwright, structured JSON output
triquetra-up.sh candidates/bergur/ \
  --provider deepseek:deepseek-chat \
  --playwright \
  --prompt-file candidates/bergur/prompts/scout.md

# Write: quality model for prose, no browser needed
triquetra-up.sh candidates/bergur/ \
  --provider anthropic:claude-sonnet-4-6 \
  --prompt-file candidates/bergur/prompts/letter-writer.md
```

The filesystem is the pipeline bus: scout writes `scout-output.json`; the letter
stage reads it. No IPC. This is already how V2 works — Triquetra just makes the
provider axis explicit.

**Practical savings estimate.** A single full pipeline run (scout across ~50 jobs +
20 letters) with Claude Sonnet today likely costs €0.30–0.80 depending on context
length. Moving scout to DeepSeek-chat and keeping only letter writing on Sonnet
could halve that cost. At 10 candidates running daily, the difference compounds.

**Modes for pipeline stages.** Scout needs Playwright (browser). Letter writing needs
LaTeX tooling (pdflatex) to compile and verify the output. These map directly to
Triquetra's mode concept:

- Scout: `--mode dev --playwright` (browser + standard tools)
- Write: `--mode data` (LaTeX, PDF rendering, future: DOCX support)

---

## 3. Triquetra pipeline patterns applied to JSP

### 3.1 Candidate init as a pipeline

The init flow (`init_candidate.sh`) calls the Anthropic API three times sequentially:
generate scout prompt → generate letter-writer prompt → generate LaTeX templates.
Each step reads the previous output. This is exactly the sequential-stages pattern.

```bash
# init as a Triquetra pipeline (conceptual)

# Stage 1: generate scout.md from CV + meta-prompt
triquetra-up.sh candidates/anna/ \
  --provider anthropic \
  --prompt-file init/meta-prompts/generate-scout.md

# Stage 2: generate letter-writer.md
triquetra-up.sh candidates/anna/ \
  --provider anthropic \
  --prompt-file init/meta-prompts/generate-letter-writer.md

# Stage 3: generate LaTeX templates
triquetra-up.sh candidates/anna/ \
  --provider anthropic \
  --prompt-file init/meta-prompts/generate-templates.md
```

The inter-stage context (`TRIQUETRA_PLAN.md` equivalent) is the candidate folder
itself — each stage reads what the previous wrote. This already works today;
formalizing it as a Triquetra pipeline adds the provider-switching option and
makes the structure visible.

### 3.2 Reasoning model for scout.md generation

Generating a good `scout.md` is a nuanced task: distill a CV into a precise,
reproducible scoring rubric. A reasoning model (DeepSeek-Reasoner or o3) is
better suited here than a fast model. The letter-writer template, by contrast,
is a writing task — Sonnet-class models do it well.

```bash
# Init with model split
triquetra-up.sh candidates/anna/ \
  --provider deepseek:deepseek-reasoner \    # reasoning model for scout
  --prompt-file init/meta-prompts/generate-scout.md

triquetra-up.sh candidates/anna/ \
  --provider anthropic:claude-sonnet-4-6 \   # prose model for letter template
  --prompt-file init/meta-prompts/generate-letter-writer.md
```

### 3.3 Conditional escalation

The fit scoring can produce uncertain cases. A conditional stage that escalates
uncertain jobs to a better model:

```bash
triquetra-up.sh candidates/bergur/ \
  --provider deepseek:deepseek-chat \
  --prompt-file prompts/scout.md \
  > /tmp/scout-log.txt 2>&1

if grep -q "UNCERTAIN_FIT" candidates/bergur/scout-output.json; then
  triquetra-up.sh candidates/bergur/ \
    --provider anthropic:claude-sonnet-4-6 \
    --prompt-file prompts/scout-review.md
fi
```

This avoids paying for the expensive model on every run, only when the cheap model
flags ambiguity.

### 3.4 Parallel candidates

`pipeline-generalization-spec.md` explicitly defers parallel multi-candidate runs.
With Triquetra, it's a one-liner at the shell level:

```bash
for candidate in bergur anna kristinn; do
  triquetra-up.sh "candidates/${candidate}/" \
    --provider deepseek \
    --playwright \
    --prompt-file "candidates/${candidate}/prompts/scout.md" &
done
wait
echo "All scouts complete"
```

Each run is an independent container. No shared state between them except the
read-only Playwright browser (which can be a separate sidecar). This works today
with `claude-up.sh` — Triquetra just gives it a clean API and the provider choice.

---

## 4. V3 SaaS: where Triquetra sits in the architecture

The V3 architecture in `/app_3/v3-architecture.md` shows a conventional
job-queue + worker model. The open question it explicitly flags is:

> *"Does the container harness (claude-in-container) have a role in V3, or is it
> replaced by a more conventional server-side worker?"*

The answer is: **both, at different layers.**

```
V3 Stack (Triquetra-aware)

[Browser UI]
     ↓
[API Server (FastAPI / Django)]
     ↓
[Job Queue (Celery / ARQ / BullMQ)]
     ↓
[Pipeline Dispatcher]
     ↓  ↓  ↓  (one Job per stage per candidate)
[Triquetra container] [Triquetra container] [Triquetra container]
     ↓                      ↓                       ↓
[Candidate data store — PVC or S3-compatible object storage]
     ↓
[Result store — Postgres]
```

The pipeline dispatcher is a lightweight Python process (part of the worker) that
translates a queue job into a sequence of Triquetra container runs. The AI
execution stays inside Triquetra containers. The queue worker itself does not call
the Anthropic API — it only launches and monitors containers.

**Why this separation matters:**

- **Isolation.** Each pipeline run is a fresh container. A runaway prompt cannot
  affect other tenants.
- **Provider flexibility.** The dispatcher can choose the provider per stage per
  user tier (e.g. basic plan → DeepSeek for all stages; premium → Claude for
  letter writing).
- **Cost metering.** Container start/stop events are natural billing hooks.
  The dispatcher can record: tenant, stage, provider, start time, end time.
- **Auditability.** The prompt files and output files per run can be archived to
  S3 for dispute resolution or debugging.

---

## 5. Kubernetes: running many pipelines for many users

Triquetra's unit model — one stateless container per pipeline stage — is naturally
Kubernetes-friendly. The local Docker Compose setup is for development and single-user
use. For V3 at scale, the translation to Kubernetes is the right path.

### 5.1 The mapping

| Triquetra concept | Kubernetes equivalent |
|-------------------|-----------------------|
| `triquetra-up.sh` invocation | `kubectl apply -f job.yaml` |
| Docker Compose service | Kubernetes Job spec |
| Host volume mount | PersistentVolumeClaim (PVC) |
| LiteLLM sidecar | Shared LiteLLM Deployment (cluster-wide) |
| `--playwright` sidecar | Init container or sidecar container in same Pod |
| Container name | Job name (tenant + candidate + stage + timestamp) |

### 5.2 Candidate data as PVCs

In V3, each candidate's working directory (the "filesystem bus") becomes a PVC:

```
pvc-tenant-a-candidate-bergur
  /prompts/scout.md
  /prompts/letter-writer.md
  /scout-output.json
  /job-prospects.yaml
  /cover_letters/
  /logs/
```

Each Kubernetes Job mounts this PVC. The scout stage writes `scout-output.json`;
the letter stage reads it. The filesystem-as-pipeline-bus pattern works unchanged —
Kubernetes just replaces the host filesystem.

For multi-region or high-availability setups, an S3-compatible object store
(MinIO, Hetzner Object Storage, AWS S3) can replace the PVC, with the Triquetra
container reading/writing through a FUSE mount or an explicit sync step.

### 5.3 Kubernetes Job template

```yaml
# triquetra-scout-job.yaml (generated by pipeline dispatcher)
apiVersion: batch/v1
kind: Job
metadata:
  name: scout-tenant-a-bergur-20260602-0830
  labels:
    tenant: tenant-a
    candidate: bergur
    stage: scout
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: registry.example.com/triquetra-claude-code:dev
          env:
            - name: ANTHROPIC_BASE_URL
              value: "https://api.deepseek.com/v1"
            - name: ANTHROPIC_MODEL
              value: "deepseek-chat"
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: provider-keys
                  key: deepseek-api-key
          command: ["/app/wrapper.sh"]
          args: ["--prompt-file", "/candidate/prompts/scout.md", "--yolo"]
          volumeMounts:
            - name: candidate-data
              mountPath: /candidate
        - name: playwright
          image: mcr.microsoft.com/playwright:v1.47.0-jammy
          # sidecar browser, reachable on localhost
      volumes:
        - name: candidate-data
          persistentVolumeClaim:
            claimName: pvc-tenant-a-bergur
```

The pipeline dispatcher generates this YAML (or calls the Kubernetes API directly)
for each stage, waits for Job completion, then dispatches the next stage.

### 5.4 Cluster-wide LiteLLM

At SaaS scale, a per-container LiteLLM sidecar is wasteful. Instead, LiteLLM runs
as a shared Kubernetes Deployment:

```
[LiteLLM Deployment]
  - Anthropic API
  - DeepSeek API
  - OpenRouter
  - Per-tenant spend tracking (LiteLLM supports this natively)
  - Rate limiting per tenant
  - Semantic caching (reduces duplicate API calls across tenants)
```

All Triquetra Jobs set `ANTHROPIC_BASE_URL=http://litellm.litellm.svc:4000`.
The LiteLLM deployment is the AI gateway for the entire cluster. Tenant routing
and provider selection happen here, not in the Job spec.

This is a significant architectural evolution: in V2, the LiteLLM sidecar is
per-container and optional. In V3, it is a shared service and becomes the control
plane for all AI inference.

### 5.5 Scaling model

```
                 ┌──────────────────────────────────────────┐
                 │  Kubernetes Cluster                       │
                 │                                          │
 ┌──────┐        │  ┌──────────────┐   ┌─────────────────┐ │
 │  API │───────►│  │  API Server  │   │ LiteLLM Gateway │ │
 │  UI  │        │  │  (Django)    │   │ (shared, HA)    │ │
 └──────┘        │  └──────┬───────┘   └────────┬────────┘ │
                 │         │                     │          │
                 │  ┌──────▼───────┐             │          │
                 │  │  Job Queue   │             │          │
                 │  │  (Celery +   │             │          │
                 │  │   Redis)     │             │          │
                 │  └──────┬───────┘             │          │
                 │         │                     │          │
                 │  ┌──────▼───────────────────┐ │          │
                 │  │  Pipeline Dispatcher     │ │          │
                 │  │  (spawns K8s Jobs)       │ │          │
                 │  └──────────────────────────┘ │          │
                 │                               │          │
                 │  ┌─────┐ ┌─────┐ ┌─────┐     │          │
                 │  │ Job │ │ Job │ │ Job │◄────┘          │
                 │  │scout│ │write│ │scout│                 │
                 │  └──┬──┘ └──┬──┘ └──┬──┘                │
                 │     │       │       │                    │
                 │  ┌──▼───────▼───────▼──┐                 │
                 │  │   PVC / Object Store │                 │
                 │  │   (per tenant/cand) │                 │
                 │  └─────────────────────┘                 │
                 └──────────────────────────────────────────┘
```

Autoscaling: Kubernetes HPA (Horizontal Pod Autoscaler) on the Job dispatcher worker.
Burst pipeline runs spin up new nodes; idle periods scale down. The Triquetra
container images are stateless, so scaling is straightforward.

---

## 6. Provider strategy for V3 and cost implications

The business model in `/app_3/business-model.md` identifies AI inference cost as a
key variable. At €0.15–0.30/run today (single candidate, one provider), multi-user
scale with absorbed inference cost is risky without a provider strategy.

Triquetra's provider abstraction directly addresses this:

| Pipeline stage | Task type | Recommended provider | Why |
|----------------|-----------|----------------------|-----|
| Scout | Web scraping + structured scoring | DeepSeek-chat or OpenRouter → Qwen | Cheap, good at structured extraction |
| Letter writing | High-quality prose | Claude Sonnet 4.6 | Product's core value; quality justifies cost |
| Init (scout.md generation) | Reasoning over CV | DeepSeek-Reasoner or o3-mini | One-time cost; reasoning quality matters |
| Init (template generation) | Writing | Claude Sonnet | Same quality argument as letter writing |
| Tracking update | Structured YAML update | DeepSeek-chat or local Ollama | Cheap, deterministic task |

Conservative estimate: this provider split reduces per-run AI cost by 40–60% vs. all
stages on Claude Sonnet. At 1,000 monthly active users running 20 pipeline runs each,
that's a meaningful margin difference.

**BYOK (Bring Your Own Key) tier:** For B2B / career coach accounts managing many
candidates, the V3 business model might offer a BYOK option where the provider
keys belong to the customer. Triquetra's provider abstraction makes this trivial to
implement — the pipeline dispatcher injects whichever keys the tenant's account record
specifies. The LiteLLM gateway handles tenant-scoped key isolation.

---

## 7. Privacy and the `--air-gap` mode

The `--air-gap` flag (air-gap mode) in Triquetra has a specific V3 use case:
career coaches handling candidates whose CV data is confidential (executives, public
figures, regulated sectors).

In V3, this becomes a premium tier feature:
- Standard: pipeline runs on shared infrastructure, cloud providers
- Private: pipeline runs with `--air-gap`, local model (Ollama + Qwen on dedicated
  nodes), candidate data never leaves the EU cluster

Kubernetes implementation: a dedicated node pool with no egress network policy, running
Ollama as an in-cluster service. Jobs tagged `tier: private` get scheduled only to
these nodes. LiteLLM routes their requests to the in-cluster Ollama rather than
external APIs.

---

## 8. LaTeX and document compilation in a containerized context

The V3 architecture doc raises the open question of LaTeX compilation in a web
context. Triquetra's mode system gives the answer:

```
modes/
  data/
    packages.txt   →  add: texlive-full, texlive-xetex, latexmk
    context.md     →  LaTeX compilation context for the agent
```

The letter-writing Triquetra container has `pdflatex` and `xelatex` available.
The agent compiles the `.tex` to `.pdf` inside the container. The PDF is written
to the PVC alongside the `.tex` source. The API server reads it from object storage
and serves it to the browser for preview.

No separate LaTeX-compilation service needed. The Triquetra container *is* the
LaTeX runner.

---

## 9. What Triquetra does NOT solve for V3

Being clear about limitations:

- **Web UI** — Triquetra is a headless pipeline tool. The browser UI, authentication,
  and user management in V3 are conventional web development; Triquetra has no opinion.

- **Job board integrations** — The scout.md prompt drives board navigation. Triquetra
  provides the Playwright-capable container; the actual scraping logic is in the prompt.
  Job board coverage (Alfred.is → Nordic boards) is a product problem, not a harness problem.

- **Tenant data isolation at the database level** — Triquetra provides filesystem-level
  isolation (per-candidate PVC). Postgres row-level security and tenant data model are
  standard web application concerns.

- **Real-time pipeline status** — Triquetra containers emit stdout/stderr logs.
  Streaming these to a web UI in real time (WebSocket, SSE) requires work in the
  API server and pipeline dispatcher. Triquetra itself is fire-and-forget.

- **Billing and metering** — LiteLLM's built-in spend tracking can serve as a data
  source, but the billing system (Stripe, invoicing) is external.

---

## 10. Recommended evolution path

### Phase 1 — V2 improvement (now, low effort)

Use Triquetra's provider-switching (Option A from `triquetra-feasibility.md`) to
route the scout stage to DeepSeek. No architectural change — just update
`pipeline-config.yaml` to call `triquetra-up.sh` instead of `claude-up.sh` with
a `--provider deepseek` flag.

Expected effort: 1 day once `triquetra-up.sh` exists. Immediate cost reduction.

### Phase 2 — V3 early (hosted V2 + minimal web UI)

The strategic-overview.md confirms the near-term plan: host V2 with a minimal web UI
for B2B career coaches by July 2026. At this stage, Triquetra containers run on a
single VPS (Hetzner). Docker Compose is sufficient. No Kubernetes yet.

The pipeline dispatcher is a simple Celery worker that calls `subprocess.run(triquetra-up.sh ...)`.
Multi-tenant isolation is by filesystem directory per tenant, not by namespace.

### Phase 3 — V3 proper (Sept–Nov 2026 per strategic-overview.md)

If user growth justifies it: migrate pipeline execution to Kubernetes Jobs.
The Triquetra container images are unchanged; only the launcher (pipeline dispatcher)
changes from shell subprocess to Kubernetes Job creation.

This migration is low-risk because Triquetra's stateless-container-per-stage model
maps cleanly to Kubernetes Jobs with no rearchitecting.

---

## 11. Open questions this analysis surfaces

1. **Should `write_letters.py` become a Triquetra container run?** Currently it calls
   the Anthropic Python SDK directly. Migrating it to a container run adds overhead
   but enables provider switching for the letter stage. Worth it when migrating to V3;
   arguably not worth it for V2 single-user.

2. **How does the pipeline dispatcher know when a Triquetra Job succeeds or fails?**
   In Docker Compose: container exit code. In Kubernetes: Job `.status.conditions`.
   Both work. The dispatcher needs to handle timeouts and retries for the scout stage
   (Playwright scraping can hang on slow job boards).

3. **What is the minimum Kubernetes setup for a small V3?** A single k3s node (Hetzner
   VPS, ~€15/month) runs the full stack for hundreds of users. Kubernetes is not
   necessarily heavy infrastructure — k3s makes it accessible from day one.

4. **GDPR and the LiteLLM gateway.** If Anthropic processes CV text, a DPA is needed.
   If DeepSeek processes it, different considerations apply (data residency, EU adequacy).
   The provider routing strategy has legal implications at V3 scale. Default routing
   to EU-hosted providers (Anthropic via EU data residency option, or OpenRouter with
   ZDR) may be required.

5. **Triquetra as open-source and V3 as proprietary.** The strategic-overview raises
   open-source vs. moat. One viable model: Triquetra (the harness) is open-source and
   builds community; JSP V3 (the product running on Triquetra) is proprietary SaaS.
   This mirrors the open-core model and gives Triquetra a real flagship use case to
   demonstrate against.
