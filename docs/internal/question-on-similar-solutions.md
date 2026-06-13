 Ok, before continuing I have one final question. In terms of the whole Trigon concept, am I, are we possibly             
  re-inventing the wheel ? Is there something like this already ? Or something very close, in terms of features and           
  capabilities ? Something open-source perhaps ?                                                                              
  
● Good question to ask before investing more. Let me do a targeted search rather than answer from training data alone.

● Web Search("Claude Code Docker container provider agnostic harness open source 2026")
  ⎿  Did 1 search in 9s

● Web Search("provider agnostic LLM coding agent Docker container switcher anthropic deepseek ollama open source")
  ⎿  Did 1 search in 11s

● Web Search("VibePod Docker Claude Code agent harness provider switching open source")
  ⎿  Did 1 search in 8s

● Web Search(""crab code" OR "code container" CLI agent harness provider agnostic Docker 2026")
  ⎿  Did 1 search in 11s

● Here's an honest assessment. The closest thing I found is VibePod, and it's worth taking seriously.

  ---
  What exists
  
  VibePod (https://github.com/VibePod/vibepod-cli) is the nearest match. It's an open-source unified CLI that runs Claude
  Code, Gemini, Codex, OpenCode, Devstral and others in isolated Docker containers with zero configuration. It has settings
  persistence and a built-in HTTP proxy for traffic monitoring. Published March 2026.

  OpenCode natively supports 75+ providers including Ollama and DeepSeek — no LiteLLM sidecar, no env var tricks needed.
  Provider switching is a first-class feature.

  Docker Sandboxes is Docker's own commercial product for running Claude Code, Codex, Gemini etc. in microVMs with project
  isolation.

  awesome-cli-coding-agents (https://github.com/bradAGI/awesome-cli-coding-agents) is a curated directory of exactly this
  category — worth reading to see the full landscape.

  ---
  Honest comparison

  Where Trigon overlaps significantly with what exists:
  - "Run Claude Code in Docker with settings persistence" — VibePod does this
  - "Run multiple agents" — VibePod does this
  - "Switch providers" — OpenCode does this natively
  
  Where Trigon is genuinely differentiated:

  1. Provider switching within Claude Code — the ANTHROPIC_BASE_URL trick to make Claude Code talk to DeepSeek or OpenRouter
  is not something VibePod does. VibePod runs Claude Code against Anthropic and OpenCode against other providers — it doesn't
  route Claude Code to a different backend. This is Trigon's most specific insight.
  2. Security mode — a Docker image with nmap, gobuster, nuclei, Go tools and an injected security context is a real, working
  thing in /app right now. Nothing in the landscape has this.
  3. Mode system generally — baking domain toolsets (dev/security/data) into images at build time and injecting context
  prompts is not something VibePod or Docker Sandboxes do.
  4. Personal pipeline integration — multi-project mounting, --prompt-file for non-interactive pipeline runs, --air-gap
  air-gap — these are your actual workflow needs that nothing off-the-shelf covers exactly.

  ---
  My actual take

  You're not reinventing the wheel in the core "agent in a Docker container" sense — VibePod exists and is live. But the wheel
   you're building has a specific shape that doesn't exist yet:

  - Cost/quality arbitrage on Claude Code (run Claude Code against DeepSeek for cheap scout passes, Anthropic for final work)
  is the main intellectual contribution of Trigon's provider layer. Nobody else does this.
  - Security mode as a proper domain toolset is real differentiation.

  The honest risk is that OpenCode with native provider support may be the better long-term answer for the "any provider" use
  case, which is why M5 (OpenCode agent) is smart to keep on the roadmap. If OpenCode matures fast, the LiteLLM-sidecar tier-2
   complexity becomes mostly irrelevant — you'd just use OpenCode directly.

  The lean version of Trigon — the one that's defensibly yours and not easily replicated by VibePod — is probably: security
   mode + data mode + multi-project mounting + prompt-file pipelines, with provider switching for Claude Code as the tier-1 
  quick win. That's a coherent, useful, publishable tool.

  Sources:
  - VibePod CLI GitHub (https://github.com/VibePod/vibepod-cli)
  - VibePod: Unified CLI for Running AI Coding Agents — Agent Wars
  (https://agent-wars.com/news/2026-03-14-vibepod-cli-ai-coding-agents-docker)
  - awesome-cli-coding-agents — GitHub (https://github.com/bradAGI/awesome-cli-coding-agents)
  - OpenCode Providers docs (https://opencode.ai/docs/providers/)
  - Docker Sandboxes (https://www.docker.com/products/docker-sandboxes/)
  - Harnss — open harness client (https://github.com/OpenSource03/harnss)

