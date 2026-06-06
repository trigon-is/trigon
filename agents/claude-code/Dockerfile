ARG MODE=dev

# ── Base: OS, Node.js, Claude Code CLI ───────────────────────────────────────
FROM ubuntu:latest AS base
RUN apt-get update && apt-get install -y \
    npm nodejs \
    python3 python3-pip python3-venv \
    git curl wget \
    ripgrep fd-find \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code

# ── Dev mode ──────────────────────────────────────────────────────────────────
FROM base AS mode-dev
COPY modes/dev/packages.txt /tmp/packages.txt
COPY modes/dev/requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && grep -v '^#\|^[[:space:]]*$' /tmp/packages.txt | xargs apt-get install -y \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt
# Playwright + Chromium for --playwright-headless
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/playwright-browsers
RUN npm install -g playwright \
    && playwright install --with-deps chromium

# ── Security mode ─────────────────────────────────────────────────────────────
FROM base AS mode-security
COPY modes/security/packages.txt /tmp/packages.txt
COPY modes/security/requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && grep -v '^#\|^[[:space:]]*$' /tmp/packages.txt | xargs apt-get install -y \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt
# Go toolchain
RUN wget -q https://go.dev/dl/go1.21.5.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz \
    && rm go1.21.5.linux-amd64.tar.gz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
ENV GOPATH=/root/go
ENV GO111MODULE=on
# Go security tools (failures tolerated — network issues at build time are transient)
RUN go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest || true
RUN go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest || true
RUN go install -v github.com/tomnomnom/assetfinder@latest || true
RUN go install -v github.com/tomnomnom/waybackurls@latest || true
RUN go install -v github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest || true
RUN go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest || true
# Security research directories and wordlists
RUN mkdir -p /security/{wordlists,tools,results,scripts} \
    && wget -q -O /security/wordlists/common.txt \
        https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/common.txt \
    && wget -q -O /security/wordlists/subdomains.txt \
        https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/subdomains-top1million-5000.txt

# ── Final: select mode, install wrapper + mode contexts ───────────────────────
FROM mode-${MODE} AS final
ARG MODE
ENV TRIQUETRA_MODE=${MODE}
COPY agents/claude-code/wrapper.sh /usr/local/bin/triquetra-wrapper
RUN chmod +x /usr/local/bin/triquetra-wrapper
COPY modes /modes
WORKDIR /app
CMD ["/usr/local/bin/triquetra-wrapper"]
