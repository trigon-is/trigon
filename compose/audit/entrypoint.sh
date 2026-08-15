#!/bin/sh
# Entrypoint for the Trigon `--audit` gateway sidecar (see docs/audit-design.md).
#
# The audited agent shares THIS container's network namespace
# (`network_mode: "service:audit-gw"` in the generated fragment), so the agent's
# outbound packets originate here and cannot leave except via this stack — the
# agent holds no NET_ADMIN and cannot re-route around us (NFR-3, NFR-9).
#
# The agent runs as uid 1000; mitmproxy runs here as uid 0. We REDIRECT the
# agent's locally-originated :80/:443 to mitmproxy's transparent listener and
# exclude uid 0 so mitmproxy's own upstream connections are not looped back
# (the documented mitmproxy same-host / uid-owner interception pattern).
#
# NOTE: the iptables rules + transparent capture are pending live-container
# verification (no Docker in dev sessions). Fail closed on any setup error so a
# misconfigured gateway never lets traffic escape unaudited (NFR-5).
set -eu

MITM_PORT="${MITM_PORT:-8080}"
MITM_UID="${MITM_UID:-0}"          # uid mitmproxy runs as; excluded from redirect
export AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-/audit-log/session.jsonl}"

echo "trigon-audit-gw: configuring transparent interception (exclude uid=${MITM_UID}, port=${MITM_PORT})"

# Redirect locally-generated TCP to mitmproxy, but never mitmproxy's own traffic.
iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "${MITM_UID}" -j RETURN
iptables -t nat -A OUTPUT -p tcp --dport 80  -j REDIRECT --to-port "${MITM_PORT}"
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port "${MITM_PORT}"

# route_localnet lets the kernel deliver the REDIRECTed packets to the local
# listener in transparent mode.
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true

# Decrypt-failure policy: pass-through-SNI (default) tunnels pinned flows opaque;
# fail-closed drops them. The addon records destination for both. confdir holds
# the per-session CA (read-only-mounted into the agent on the decrypt path).
MITM_ARGS="--mode transparent --showhost --set block_global=false --set confdir=/audit-log/.mitmproxy"
if [ "${AUDIT_DECRYPT:-0}" = "1" ] && [ "${AUDIT_DECRYPT_FAIL_CLOSED:-0}" = "1" ]; then
  MITM_ARGS="${MITM_ARGS} --set connection_strategy=eager"
fi

echo "trigon-audit-gw: starting mitmdump (decrypt=${AUDIT_DECRYPT:-0})"
# shellcheck disable=SC2086
exec mitmdump -q --listen-port "${MITM_PORT}" ${MITM_ARGS} -s /opt/audit/audit_addon.py
