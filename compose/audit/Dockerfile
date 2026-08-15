# Trigon `--audit` gateway image.
#
# The stock mitmproxy image ships mitmdump but NOT the tooling the transparent
# gateway needs, so the sidecar's entrypoint (which sets iptables REDIRECT rules)
# exits 127. This image layers that tooling on:
#   - iptables : the transparent REDIRECT of the agent's :80/:443 to mitmproxy
#   - procps   : pgrep / sysctl used by the entrypoint + healthcheck
#
# Build:  ./build.sh --audit-gateway   →   trigon-audit-gw:latest
#
# Supply chain (NFR-6 / SECURITY-13): pin the base by DIGEST before release —
# override MITMPROXY_BASE with mitmproxy/mitmproxy@sha256:<digest>. The version
# tag below is the verified floor.
ARG MITMPROXY_BASE=mitmproxy/mitmproxy:11.1.3
FROM ${MITMPROXY_BASE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables procps \
 && rm -rf /var/lib/apt/lists/*

# No ENTRYPOINT/CMD: the generated compose fragment sets the entrypoint to
# compose/audit/entrypoint.sh (mounted read-only) and runs as uid 0.
