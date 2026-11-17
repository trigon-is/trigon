#!/bin/sh
# Entrypoint for the Trigon `--audit` gateway sidecar (see docs/audit-design.md).
#
# The audited agent shares THIS container's network namespace
# (`network_mode: "service:audit-gw"` in the generated fragment), so the agent's
# outbound packets originate here and cannot leave except via this stack — the
# agent holds no NET_ADMIN and cannot re-route around us (NFR-3, NFR-9).
#
# The agent runs as the host user's uid; mitmproxy runs here as uid 0. Every
# uid except 0 is "the agent" below. The rules make the coverage claim literal
# (docs/audit-design.md §3.1, threat-model G6):
#   - every outbound TCP connection is REDIRECTed to mitmproxy's transparent
#     listener, so it is logged by destination whatever its port;
#   - UDP (incl. QUIC), ICMP and every other protocol is REJECTed (not DROPped,
#     so clients fall back to TCP at once) and counted; the addon writes the
#     counters into the log as a "blocked" record at shutdown;
#   - DNS (udp/53) stays allowed until it is logged (Batch 3);
#   - IPv6 is off (compose sysctls) with an ip6tables reject-all behind it.
# Loopback and uid 0 are exempt: mitmproxy's own upstream connections must not
# loop back into itself (the documented mitmproxy uid-owner pattern). That is
# why --audit refuses --root and a root host user (trigon-up.sh).
#
# Fail closed on any setup error (set -e, NFR-5): the gateway never turns
# healthy, so compose never starts the agent unaudited.
set -eu

MITM_PORT="${MITM_PORT:-8080}"
MITM_UID="${MITM_UID:-0}"          # uid mitmproxy runs as; excluded from redirect
export AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-/audit-log/session.jsonl}"

echo "trigon-audit-gw: redirecting all TCP to :${MITM_PORT}, rejecting other egress (exempt: lo, uid ${MITM_UID})"

# The kernel settings come from the compose fragment (`sysctls:`): /proc/sys is
# read-only in an unprivileged container, so `sysctl -w` here would fail. Check
# them instead of trusting them — a gateway started some other way must not
# come up with IPv6 live.
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]; then
  echo "trigon-audit-gw: IPv6 is not disabled (net.ipv6.conf.all.disable_ipv6 != 1); refusing to start" >&2
  exit 1
fi

# nat: send every new outbound TCP connection to mitmproxy.
iptables -t nat -N TRIGON_AUDIT
iptables -t nat -A TRIGON_AUDIT -o lo -j RETURN
iptables -t nat -A TRIGON_AUDIT -m owner --uid-owner "${MITM_UID}" -j RETURN
iptables -t nat -A TRIGON_AUDIT -p tcp -j REDIRECT --to-port "${MITM_PORT}"
iptables -t nat -A OUTPUT -p tcp -j TRIGON_AUDIT

# filter: what isn't redirected TCP, loopback or DNS doesn't leave. The
# `trigon-blocked:<name>` comments are how the addon finds the counters.
iptables -N TRIGON_EGRESS
iptables -A TRIGON_EGRESS -o lo -j ACCEPT
iptables -A TRIGON_EGRESS -m owner --uid-owner "${MITM_UID}" -j ACCEPT
# New outbound TCP was redirected above; what still matches here is the
# agent's side of connections made to it.
iptables -A TRIGON_EGRESS -p tcp -j ACCEPT
iptables -A TRIGON_EGRESS -p udp --dport 53 -j ACCEPT   # DNS — unlogged until Batch 3
iptables -A TRIGON_EGRESS -p udp  -m comment --comment trigon-blocked:udp  -j REJECT --reject-with icmp-port-unreachable
iptables -A TRIGON_EGRESS -p icmp -m comment --comment trigon-blocked:icmp -j REJECT --reject-with icmp-admin-prohibited
iptables -A TRIGON_EGRESS         -m comment --comment trigon-blocked:other -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -j TRIGON_EGRESS

# IPv6 is disabled; reject anyway in case a v6 address ever appears.
ip6tables -N TRIGON_EGRESS
ip6tables -A TRIGON_EGRESS -o lo -j ACCEPT
ip6tables -A TRIGON_EGRESS -m comment --comment trigon-blocked:ipv6 -j REJECT
ip6tables -A OUTPUT -j TRIGON_EGRESS

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
