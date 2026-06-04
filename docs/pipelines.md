# Pipelines

Triquetra does not orchestrate multi-step pipelines internally. Each invocation
is a stateless unit. Pipelines are built by chaining invocations from outside —
shell scripts, Makefiles, CI workflows, or an external orchestrator.

This document covers patterns, examples, and tips for building pipelines with
Triquetra containers as building blocks.

---

## The unit model

A single Triquetra run:

```
INPUT: project directory + prompt file + provider + agent + mode
PROCESS: container runs, agent executes prompt against the project
OUTPUT: modified files in project directory + stdout/stderr logs
```

The project directory is a shared volume. Output from one stage is naturally
available to the next stage because both mount the same directory.

```
Stage 1                Stage 2                Stage 3
──────────             ──────────             ──────────
~/project ──read──►    ~/project ──read──►    ~/project ──read──►
          ◄──write──   prompt-1 output        prompt-2 output
```

No IPC, no message queues. The filesystem is the pipeline bus.

---

## Basic patterns

### Sequential stages

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT=~/my-project

# Stage 1: plan (reasoning model)
./triquetra-up.sh "$PROJECT" \
  --provider deepseek:deepseek-reasoner \
  --prompt-file ./prompts/01-analyse.md

# Stage 2: implement (fast model)
./triquetra-up.sh "$PROJECT" \
  --provider deepseek:deepseek-chat \
  --prompt-file ./prompts/02-implement.md

# Stage 3: review (local, code stays on machine)
./triquetra-up.sh "$PROJECT" \
  --provider ollama:qwen2.5-coder:7b \
  --no-internet \
  --prompt-file ./prompts/03-review.md

# Stage 4: security check (security mode)
./triquetra-up.sh "$PROJECT" \
  --mode security \
  --provider anthropic \
  --prompt-file ./prompts/04-security-check.md
```

---

### Conditional stages

```bash
# Only run expensive model if cheaper one flags uncertainty
./triquetra-up.sh "$PROJECT" --provider deepseek \
  --prompt-file ./prompts/quick-check.md \
  > /tmp/check-output.txt 2>&1

if grep -q "NEEDS_REVIEW" /tmp/check-output.txt; then
  ./triquetra-up.sh "$PROJECT" --provider anthropic \
    --prompt-file ./prompts/deep-review.md
fi
```

---

### Parallel independent tasks

```bash
# Run two independent tasks on different sub-directories simultaneously
./triquetra-up.sh ~/project/frontend \
  --provider deepseek \
  --prompt-file ./prompts/frontend-audit.md &

./triquetra-up.sh ~/project/backend \
  --provider deepseek \
  --prompt-file ./prompts/backend-audit.md &

wait
echo "Both tasks complete"
```

---

### Cost-ladder routing

Route to the cheapest model that can handle the task:

```bash
run_with_fallback() {
  local project=$1
  local prompt=$2

  # Try cheap first
  ./triquetra-up.sh "$project" --provider ollama:qwen2.5-coder:7b \
    --no-internet --prompt-file "$prompt" && return 0

  # Escalate to mid-tier
  ./triquetra-up.sh "$project" --provider deepseek \
    --prompt-file "$prompt" && return 0

  # Final escalation
  ./triquetra-up.sh "$project" --provider anthropic \
    --prompt-file "$prompt"
}
```

---

### Passing context between stages

Write structured output in stage N for stage N+1 to consume:

```markdown
<!-- prompts/01-analyse.md -->
Analyse the codebase and write your findings to /app/TRIQUETRA_PLAN.md.
Use this format:

## Issues Found
...

## Recommended Changes
...
```

```markdown
<!-- prompts/02-implement.md -->
Read /app/TRIQUETRA_PLAN.md (written by the analysis stage).
Implement the recommended changes listed there.
```

The `TRIQUETRA_PLAN.md` file persists in the project directory between runs.
Delete it before re-running the pipeline to avoid stale context.

---

## Prompt file conventions

Prompt files are plain Markdown. Useful conventions:

```markdown
# Task: [Stage name]

## Context
Brief description of what happened in prior stages (if relevant).

## Input
What files or data to read. Be explicit.

## Task
What to do. Be specific.

## Output
What files to write or what changes to make.
Write results to: /app/TRIQUETRA_OUTPUT.md
```

Keep prompt files in a `prompts/` directory versioned alongside the code.

---

## Makefile integration

```makefile
PROJECT ?= $(shell pwd)
PROVIDER ?= deepseek

.PHONY: plan implement review audit

plan:
	./triquetra-up.sh $(PROJECT) --provider $(PROVIDER):deepseek-reasoner \
	  --prompt-file prompts/plan.md

implement:
	./triquetra-up.sh $(PROJECT) --provider $(PROVIDER) \
	  --prompt-file prompts/implement.md

review:
	./triquetra-up.sh $(PROJECT) --provider ollama:qwen2.5-coder:7b \
	  --no-internet --prompt-file prompts/review.md

audit:
	./triquetra-up.sh $(PROJECT) --mode security --provider anthropic \
	  --prompt-file prompts/security-audit.md

pipeline: plan implement review audit
```

```bash
make pipeline
make pipeline PROJECT=~/other-project PROVIDER=anthropic
```

---

## CI / GitHub Actions integration

```yaml
# .github/workflows/ai-review.yml
name: AI code review

on:
  pull_request:

jobs:
  triquetra-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Triquetra
        run: |
          git clone https://github.com/your-org/triquetra.git /opt/triquetra
          cd /opt/triquetra && ./build.sh --agent claude-code --mode dev

      - name: Run review pipeline
        env:
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          /opt/triquetra/triquetra-up.sh ${{ github.workspace }} \
            --provider deepseek \
            --prompt-file /opt/triquetra/prompts/pr-review.md \
            --max-budget 0.50
```

---

## Reasoning model + coding model split

This is a high-value pattern: use a reasoning/chain-of-thought model to generate
a detailed plan, then hand the plan to a fast coding model for execution.

```bash
# Stage 1: reasoning model generates a detailed implementation plan
./triquetra-up.sh ~/project \
  --provider deepseek:deepseek-reasoner \
  --prompt-file prompts/reason-about-feature.md
# Output: /app/IMPLEMENTATION_PLAN.md

# Stage 2: fast model executes the plan
./triquetra-up.sh ~/project \
  --provider deepseek:deepseek-chat \
  --prompt-file prompts/execute-plan.md
# Reads: /app/IMPLEMENTATION_PLAN.md
# Output: modified source files

# Stage 3: local model reviews the diff privately
./triquetra-up.sh ~/project \
  --provider ollama:qwen2.5-coder:7b \
  --no-internet \
  --prompt-file prompts/review-diff.md
```

Cost comparison vs. doing everything with Claude Sonnet:
- Full Sonnet pipeline: ~$X
- Reasoner plan + DeepSeek execute + Ollama review: potentially 5–10× cheaper
  depending on task size

---

## Spend control

```bash
# Hard cap: container exits if this budget is exceeded
MAX_BUDGET_USD=1.00 ./triquetra-up.sh ~/project \
  --provider anthropic \
  --prompt-file prompts/big-task.md

# Soft estimation: run with cheap model first to gauge task complexity
./triquetra-up.sh ~/project \
  --provider deepseek \
  --prompt-file prompts/estimate-complexity.md
```

---

## Anti-patterns

**Don't put orchestration logic inside prompt files.** A prompt that says "first
do X, then do Y, then do Z" is fragile. Split into separate prompt files and
control sequencing from the shell.

**Don't share containers between stages.** Each stage should be a fresh
`triquetra-up.sh` call. Session state from one stage can corrupt the next.

**Don't use `--yolo` in pipelines.** Without permission prompts, a runaway
pipeline stage can make destructive changes. Gate `--yolo` to interactive use only.

**Don't leave `TRIQUETRA_PLAN.md` / inter-stage files in the repo.** Add them to
`.gitignore`. They are ephemeral pipeline state, not project artifacts.
