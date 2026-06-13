# Modes

A mode bundles a domain-specific toolset into the container and injects a
context prompt so the agent is immediately aware of the available tools and
how to use them. Modes are independent of provider and agent — any combination
is valid.

---

## How modes work

At build time, each mode contributes:
- A set of system packages (apt)
- A set of Python packages (pip)
- Optionally: language runtimes, compiled tools (Go, Rust binaries)

At runtime, the agent `wrapper.sh` reads the mode's `context.md` and injects
it into the agent's startup context. For Claude Code this means writing a
`.trigon-context` file in the working directory that the agent reads as
additional project context.

```
modes/
  dev/
    packages.txt       # apt packages
    requirements.txt   # pip packages
    context.md         # tool-awareness prompt, injected at startup
  security/
    packages.txt
    requirements.txt
    go-tools.txt       # go install targets
    context.md
  data/
    packages.txt
    requirements.txt
    context.md
```

---

## Supported modes

### `dev` (default)

General software development. The baseline mode inherited from `claude-in-container`.

**Included tools:**
- Python: `django`, `djangorestframework`, `black`, `flake8`, `pytest`, `mypy`, `isort`
- Database: `postgresql-client`, `sqlite3`
- System: `git`, `ripgrep`, `fd-find`, `nodejs`, `npm`, `curl`

**Context injected:** none (dev mode is the neutral baseline)

```bash
./trigon-up.sh ~/django-app
./trigon-up.sh ~/django-app --mode dev   # explicit
```

---

### `security`

Penetration testing, security research, and vulnerability analysis. Ported from
the `claude-in-container` `--security` mode.

**Included tools:**

*Reconnaissance & subdomain discovery:*
- `subfinder`, `assetfinder`, `httpx`

*Port scanning:*
- `nmap`, `masscan`, `naabu`

*Web application testing:*
- `gobuster`, `ffuf`, `nikto`, `nuclei` (with templates)

*Network analysis:*
- `tshark`, `tcpdump`, `netcat`

*OSINT:*
- `whois`, `dig`, `waybackurls`

*Password & crypto:*
- `hashcat`, `john`

*Forensics:*
- `binwalk`, `foremost`

*Wordlists:* `/security/wordlists/common.txt`, `subdomains-top1million-5000.txt`

*Results directory:* `/security/results/` (bind-mounted to `./security-results/` on host)

**Context injected:** full tool inventory and example workflows (see
`modes/security/context.md`).

```bash
./trigon-up.sh ~/target-app --mode security
./trigon-up.sh ~/target-app --mode security --provider deepseek
./trigon-up.sh ~/target-app --mode security --prompt-file ./prompts/recon.md
```

**Note:** Always ensure proper authorisation before using security tools against
any target. The container does not enforce this.

**VPN support:** if `/vpn/configs/client.ovpn` is present in the container, the
security mode wrapper will attempt an OpenVPN connection at startup.

---

### `data` (planned)

Data science, analytics, and ML engineering. Not yet implemented.

**Planned tools:**
- Python: `pandas`, `numpy`, `scipy`, `scikit-learn`, `matplotlib`, `seaborn`,
  `jupyterlab`, `dbt-core`, `sqlalchemy`, `polars`
- System: `postgresql-client`, `redis-tools`
- Optional: `spark`, `duckdb`

**Context injected:** data tool inventory and common workflow patterns.

```bash
./trigon-up.sh ~/analytics-project --mode data
./trigon-up.sh ~/analytics-project --mode data --provider ollama:qwen2.5
```

---

## Mode × provider combinations

Some combinations are particularly useful:

| Use case | Mode | Provider | Rationale |
|----------|------|----------|-----------|
| Daily dev work | dev | anthropic | Best general capability |
| Cost-sensitive dev | dev | deepseek | ~4× cheaper, strong coding |
| Sensitive codebase | dev | ollama:qwen2.5 + --air-gap | Code never leaves machine |
| Security audit | security | anthropic | Anthropic best for reasoning chains |
| CTF / rapid recon | security | deepseek | Fast + cheap for iterative recon |
| Local security research | security | ollama:qwen2.5 + --air-gap | Air-gapped |
| Data analysis | data | anthropic | Complex reasoning over data |
| Bulk data processing | data | deepseek | Pipeline cost reduction |

---

## Adding a new mode

1. Create `modes/mymode/` directory
2. Add `packages.txt` — one apt package per line
3. Add `requirements.txt` — one pip package per line
4. Add `context.md` — the tool-awareness prompt to inject at startup
5. If Go or Rust tools are needed, add `go-tools.txt` or `rust-tools.txt`
6. Update `agents/claude-code/Dockerfile` and `agents/opencode/Dockerfile` to
   include mode packages via build args:
   ```dockerfile
   ARG MODE=dev
   COPY modes/${MODE}/packages.txt /tmp/
   RUN apt-get install -y $(cat /tmp/packages.txt)
   ```
7. Update `trigon-up.sh` to pass `--build-arg MODE=mymode`
8. Document in this file

---

## Build strategy

Each agent+mode combination produces a distinct Docker image. Images are tagged:

```
trigon-claude-code-dev
trigon-claude-code-security
trigon-opencode-dev
```

The `build.sh` script builds all combinations:

```bash
./build.sh                      # build all
./build.sh --agent claude-code  # build one agent, all modes
./build.sh --mode security      # build all agents in security mode
```

Pre-built images keep startup time low. Mode packages are baked in at build
time — no runtime package installation.
