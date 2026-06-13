ARG MODE=dev

# ── Base: OS, Node.js, OpenCode CLI ──────────────────────────────────────────
FROM ubuntu:24.04 AS base
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv \
    git curl wget \
    ripgrep fd-find \
    && rm -rf /var/lib/apt/lists/*
ARG OPENCODE_VERSION=latest
RUN curl -fsSL https://opencode.ai/install | bash && \
    cp /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    chmod 755 /usr/local/bin/opencode

# ── Dev mode ──────────────────────────────────────────────────────────────────
FROM base AS mode-dev
COPY modes/dev/packages.txt /tmp/packages.txt
COPY modes/dev/requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && grep -v '^#\|^[[:space:]]*$' /tmp/packages.txt | xargs apt-get install -y \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt

# ── Final ─────────────────────────────────────────────────────────────────────
FROM mode-${MODE} AS final
ARG MODE
ENV TRIGON_MODE=${MODE}
COPY agents/opencode/wrapper.sh /usr/local/bin/trigon-wrapper
RUN chmod +x /usr/local/bin/trigon-wrapper
COPY modes /modes
WORKDIR /app
CMD ["/usr/local/bin/trigon-wrapper"]
