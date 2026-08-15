# Trigon documentation

This directory holds the reference documentation. For the project overview,
quick start, flags, and installation, see the **[root README](../README.md)**.

## Reference

- **[providers.md](providers.md)** — every supported provider, configuration,
  model aliases, privacy notes, remote Ollama over SSH, and adding a provider
- **[agents.md](agents.md)** — supported agents (`claude-code`, `opencode`),
  their differences, and adding an agent
- **[modes.md](modes.md)** — domain toolsets (`dev`, `security`, `data`) and
  adding a mode
- **[pipelines.md](pipelines.md)** — external orchestration patterns and CI integration
- **[trigon-architecture.md](trigon-architecture.md)** — design rationale and internals
- **[audit-concepts.md](audit-concepts.md)** — network-auditing concepts: completeness
  vs. depth, hostile agents, and why decryption is a soft guarantee (reasoning, not spec)

## Project

- **[v1_milestones_roadmap.md](v1_milestones_roadmap.md)** — milestone detail and gate conditions
- **[session-start.md](session-start.md)** — session primer for resuming development

## Other

- **[aidlc/](aidlc/)** — vendored AI-DLC workflow rules (reference for larger features)
- **[internal/](internal/)** — planning and strategy docs (not user-facing)
