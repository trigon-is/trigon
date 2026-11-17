#!/usr/bin/env bash
# pass/fail/skip always return 0, so `cond && pass … || fail …` is a safe
# if/else here; the backticks in the prompt are literal text for the agent.
# shellcheck disable=SC2015,SC2016
# Host smoke test for M7 --audit Batch 2 (coverage): every agent TCP connection
# is logged whatever its port; UDP/QUIC, ICMP and IPv6 are refused fast; the
# refusals land in the log as a "blocked" record; Claude Code still works; the
# chain still verifies. Needs Docker, so run it on the host, from anywhere:
#
#   tests/smoke/audit-batch2.sh
#
# Safe next to a running Trigon session: it starts one container named
# smoke-net in its own trigon-smoke-net-* compose project, uses the smoke
# settings dir (~/.trigon-settings-smoke, same login as audit-batch1.sh), and
# works in /tmp/trigon-smoke2. It never stops or removes anything it didn't start.
#
# The probes run inside the agent container as the agent's uid: the agent is
# asked to run probe.py, which tries each kind of egress and writes probe.json.
# (The dev image has no ping/nc and its curl has no HTTP/3, so the probes are
# plain Python sockets.)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRIGON="$REPO/trigon-up.sh"
VERIFY=(python3 "$REPO/lib/audit_summary.py" --verify)
WORK="${SMOKE_WORK:-/tmp/trigon-smoke2}"
PROJ="$WORK/net"
SMOKE_SETTINGS="${SMOKE_SETTINGS:-$HOME/.trigon-settings-smoke}"
AUDIT_ROOT="${TRIGON_AUDIT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/trigon/audit}"
GW_IMAGE="${TRIGON_AUDIT_IMAGE:-trigon-audit-gw:latest}"

PASSES=0; FAILS=0; SKIPS=0
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s━━ %s%s\n' "$B" "$1" "$N"; printf '   why: %s\n' "$2"; }
pass() { printf '   %sPASS%s %s\n' "$G" "$N" "$1"; PASSES=$((PASSES+1)); }
fail() { printf '   %sFAIL%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS+1)); }
skip() { printf '   %sSKIP%s %s\n' "$Y" "$N" "$1"; SKIPS=$((SKIPS+1)); }
note() { printf '        %s\n' "$1"; }

# ── 0. Preflight ──────────────────────────────────────────────────────────────
step "0. Preflight" "the session needs Docker, a gateway image with ip6tables, and a logged-in agent."
[[ "$(id -u)" -ne 0 ]] || { fail "run this as your normal user, not root"; exit 1; }
command -v docker >/dev/null || { fail "docker not found — run this on the Docker host"; exit 1; }
if ! docker image inspect "$GW_IMAGE" >/dev/null 2>&1; then
  note "gateway image missing — building it (./build.sh --audit-gateway)"
  "$REPO/build.sh" --audit-gateway || { fail "gateway image build failed"; exit 1; }
fi
if tools="$(docker run --rm --entrypoint sh "$GW_IMAGE" -c 'command -v iptables && command -v ip6tables' 2>&1)"; then
  pass "$GW_IMAGE has iptables + ip6tables"
else
  fail "$GW_IMAGE lacks ip6tables (the gateway would refuse to start). Rebuild it:"
  note "  $REPO/build.sh --audit-gateway"; note "$tools"
  exit 1
fi

AUTH_ARGS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_ARGS=(--api)
  pass "using ANTHROPIC_API_KEY for the smoke session"
elif [[ -f "$SMOKE_SETTINGS/.claude/.credentials.json" ]]; then
  pass "using the smoke login in $SMOKE_SETTINGS"
else
  fail "no login for the smoke session yet. Do this once, then re-run this script:"
  note "  CLAUDE_SETTINGS_DIR=$SMOKE_SETTINGS $TRIGON $PROJ --name smoke-login"
  note "  (inside: type /login, finish the browser login, then /exit)"
  mkdir -p "$PROJ"
  exit 1
fi

if ! rm -rf "$WORK" 2>/dev/null; then
  fail "$WORK holds files your user can't delete (left by an earlier sudo/root run)."
  note "Remove it, then re-run this script:  sudo rm -rf $WORK"
  exit 1
fi
mkdir -p "$PROJ"

# The probes. Each one records ok (the traffic got out), elapsed seconds and
# the error. "Refused fast" means an error well inside the timeout; a timeout
# means the packet was dropped silently or went somewhere and got no answer.
cat > "$PROJ/probe.py" <<'PY'
import json, os, socket, struct, time

TIMEOUT = 3.0
results = {}

def probe(name, fn):
    t0 = time.monotonic()
    try:
        detail = fn()
        results[name] = {"ok": True, "detail": detail}
    except socket.timeout:
        results[name] = {"ok": False, "error": "timeout"}
    except OSError as exc:
        results[name] = {"ok": False, "error": "%s (errno %s)" % (exc.strerror or exc, exc.errno)}
    results[name]["elapsed"] = round(time.monotonic() - t0, 3)

def tcp_banner(host, port):
    def fn():
        with socket.create_connection((host, port), timeout=10) as s:
            s.settimeout(10)
            return s.recv(64).decode("ascii", "replace").strip()
    return fn

def https_head(host):
    def fn():
        import ssl
        ctx = ssl.create_default_context()
        with socket.create_connection((host, 443), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                s.sendall(b"HEAD / HTTP/1.1\r\nHost: " + host.encode() + b"\r\nConnection: close\r\n\r\n")
                return s.recv(64).decode("ascii", "replace").splitlines()[0]
    return fn

def udp(addr, payload, family=socket.AF_INET):
    def fn():
        with socket.socket(family, socket.SOCK_DGRAM) as s:
            s.settimeout(TIMEOUT)
            s.connect(addr)
            s.send(payload)
            return "reply %d bytes" % len(s.recv(2048))
    return fn

def icmp_echo(ip):
    def fn():
        # Unprivileged "ping socket": allowed by Docker's default ping_group_range.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP) as s:
            s.settimeout(TIMEOUT)
            s.connect((ip, 0))
            s.send(struct.pack("!BBHHH", 8, 0, 0, 0, 1) + b"trigon")
            return "reply %d bytes" % len(s.recv(2048))
    return fn

def tcp6(ip, port):
    def fn():
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
            s.settimeout(TIMEOUT)
            s.connect((ip, port))
            return "connected"
    return fn

def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as exc:
        return "unreadable: %s" % exc

probe("dns_lookup", lambda: socket.gethostbyname("github.com"))
probe("tcp_443", https_head("example.com"))
probe("tcp_22", tcp_banner("github.com", 22))
probe("udp_quic", udp(("1.1.1.1", 443), b"\xc0" + b"\x00" * 1199))
probe("udp_ntp", udp(("162.159.200.1", 123), b"\x1b" + b"\x00" * 47))
probe("icmp_ping", icmp_echo("1.1.1.1"))
probe("tcp6", tcp6("2606:4700:4700::1111", 443))
# Usable routes only: the kernel keeps its built-in reject routes (flag
# RTF_REJECT, 0x0200) in the table even with IPv6 disabled.
routes = read("/proc/net/ipv6_route")
usable = [l for l in routes.splitlines()
          if len(l.split()) > 8 and not int(l.split()[8], 16) & 0x0200]
results["ipv6_state"] = {
    "disable_ipv6": read("/proc/sys/net/ipv6/conf/all/disable_ipv6").strip(),
    "if_inet6": read("/proc/net/if_inet6").strip(),
    "ipv6_route": "\n".join(usable) if not routes.startswith("unreadable") else routes,
}
results["uid"] = os.getuid()

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe.json")
with open(out, "w") as fh:
    json.dump(results, fh, indent=1)
print("PROBE DONE: %d probes, results in probe.json" % (len(results) - 2))
PY
printf '%s\n' 'Run `python3 probe.py` in the current directory exactly once, then reply with the last line it printed. Do not edit or create any files yourself.' > "$WORK/prompt.md"

# ── 1. Session with the probes ────────────────────────────────────────────────
step "1. One --audit session runs the probes" \
     "the probes must run as the agent's uid inside the agent container, behind the gateway."
note "starting smoke-net (output: $WORK/net.out)…"
CLAUDE_SETTINGS_DIR="$SMOKE_SETTINGS" "$TRIGON" "$PROJ" --name smoke-net --audit --yolo \
  --prompt-file "$WORK/prompt.md" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} </dev/null >"$WORK/net.out" 2>&1 &
PID=$!

# While it runs, read the gateway's rules and sysctls from outside.
gw=""
for _ in $(seq 1 60); do
  gw="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^trigon-smoke-net-.*audit-gw' || true)"
  [[ -n "$gw" ]] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if [[ -n "$gw" ]]; then
  sleep 3   # the entrypoint installs the rules before mitmdump becomes healthy
  docker exec "$gw" sh -c 'echo "## iptables -S"; iptables -S; echo "## iptables -t nat -S"; iptables -t nat -S;
    echo "## ip6tables -S"; ip6tables -S;
    echo "## disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)";
    echo "## route_localnet=$(cat /proc/sys/net/ipv4/conf/all/route_localnet)"' >"$WORK/gw-rules.txt" 2>&1
fi

wait "$PID"; rc=$?
[[ $rc -eq 0 ]] && pass "session exited 0" || fail "session exited $rc — see $WORK/net.out"

step "1b. Gateway rules and sysctls are in place" \
     "all TCP redirected (no port filter), the rest rejected, IPv6 off, route_localnet on."
if [[ -s "$WORK/gw-rules.txt" ]]; then
  rules="$(cat "$WORK/gw-rules.txt")"
  grep -q -- '-A TRIGON_AUDIT -p tcp -j REDIRECT --to-ports 8080' <<<"$rules" \
    && pass "nat: every TCP connection redirected to :8080" || fail "nat REDIRECT rule missing (see $WORK/gw-rules.txt)"
  grep -q -- '--dport 443' <<<"$rules" && fail "a port-filtered redirect is still there" || pass "no port filter on the redirect"
  n="$(grep -c -- 'trigon-blocked:.*-j REJECT' <<<"$rules")"
  [[ "$n" -eq 4 ]] && pass "4 REJECT rules (udp, icmp, other, ipv6)" || fail "expected 4 tagged REJECT rules, found $n"
  grep -q '## disable_ipv6=1' <<<"$rules" && pass "IPv6 disabled in the gateway netns" || fail "disable_ipv6 is not 1"
  grep -q '## route_localnet=1' <<<"$rules" && pass "route_localnet=1" || fail "route_localnet is not 1"
else
  fail "could not read the gateway's rules (gateway container: '${gw:-not seen}')"
fi

# ── 2. Probe results ──────────────────────────────────────────────────────────
PJ="$PROJ/probe.json"
# probe NAME FIELD → the field of one probe result, empty if absent.
probe() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get(sys.argv[2],{}); v=r.get(sys.argv[3],""); print(v if not isinstance(v,bool) else str(v).lower())' "$PJ" "$1" "$2" 2>/dev/null; }
# refused_fast NAME → pass if the probe failed with an error inside 1s.
refused_fast() {
  local ok el err
  ok="$(probe "$1" ok)"; el="$(probe "$1" elapsed)"; err="$(probe "$1" error)"
  if [[ "$ok" == "false" && "$err" != "timeout" ]] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1 else 1)" "${el:-9}"; then
    pass "$2 refused in ${el}s: $err"
  elif [[ "$ok" == "true" ]]; then
    fail "$2 GOT OUT: $(probe "$1" detail)"
  else
    fail "$2 not refused fast: ${err:-?} after ${el:-?}s (dropped silently?)"
  fi
}

step "2. Claude Code still works through the gateway" \
     "the agent had to reach its provider to run the probe at all."
if [[ -f "$PJ" ]]; then
  pass "the agent ran probe.py (uid $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uid"])' "$PJ"))"
else
  fail "no $PJ — the agent didn't run the probe; see $WORK/net.out"
fi

if [[ -f "$PJ" ]]; then
  step "2b. TCP still works, on any port" "443 as before; 22 is new (server-speaks-first, passed through)."
  [[ "$(probe dns_lookup ok)" == "true" ]] && pass "DNS lookup works (still allowed, Batch 3 logs it)" || fail "DNS lookup failed: $(probe dns_lookup error)"
  [[ "$(probe tcp_443 ok)" == "true" ]] && pass "https://example.com: $(probe tcp_443 detail)" || fail "tcp/443 failed: $(probe tcp_443 error)"
  [[ "$(probe tcp_22 detail)" == SSH-* ]] && pass "github.com:22 banner: $(probe tcp_22 detail)" || fail "tcp/22 failed: $(probe tcp_22 error)$(probe tcp_22 detail)"

  step "2c. UDP (incl. QUIC) and ICMP are refused fast" \
       "REJECT, not DROP: clients must fail or fall back to TCP at once."
  refused_fast udp_quic "UDP 1.1.1.1:443 (QUIC-shaped)"
  refused_fast udp_ntp  "UDP 162.159.200.1:123 (NTP)"
  if [[ "$(probe icmp_ping error)" == *"errno 13"* ]]; then
    pass "ICMP ping socket not even available to the agent: $(probe icmp_ping error)"
  else
    refused_fast icmp_ping "ICMP echo to 1.1.1.1"
  fi

  step "2d. No IPv6" "IPv6 must not be a way around the IPv4 rules."
  state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipv6_state"][sys.argv[2]])' "$PJ" "$1"; }
  [[ "$(state disable_ipv6)" == "1" ]] && pass "disable_ipv6=1 in the agent's netns" || fail "disable_ipv6=$(state disable_ipv6)"
  [[ -z "$(state if_inet6)" ]] && pass "no IPv6 addresses" || { fail "IPv6 addresses present:"; note "$(state if_inet6)"; }
  [[ -z "$(state ipv6_route)" || "$(state ipv6_route)" == unreadable* ]] && pass "no usable IPv6 routes" || { fail "IPv6 routes present:"; note "$(state ipv6_route)"; }
  [[ "$(probe tcp6 ok)" == "false" ]] && pass "IPv6 connect fails: $(probe tcp6 error)" || fail "IPv6 connect succeeded"
fi

# ── 3. The log ────────────────────────────────────────────────────────────────
step "3. The log shows the non-443 connection and the blocked record" \
     "port 22 must be logged like 443; refusals must be counted, not silent."
# shellcheck disable=SC2012  # our own paths; newest first is the point
log="$(ls -t "$AUDIT_ROOT"/net-*/session-trigon-smoke-net-*.jsonl 2>/dev/null | head -1)"
if [[ -n "$log" ]]; then
  pass "log: $log"
  facts="$(python3 - "$log" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
conns = [r for r in recs if r.get("type") != "blocked"]
blocked = [r for r in recs if r.get("type") == "blocked"]
print("port22=%d" % sum(1 for r in conns if r.get("dst_port") == 22))
print("provider=%d" % sum(1 for r in conns if "anthropic.com" in (r.get("dst_host") or "")))
print("ports=%s" % ",".join(str(p) for p in sorted({r.get("dst_port") for r in conns if r.get("dst_port")})))
print("blocked_last=%d" % (1 if recs and recs[-1].get("type") == "blocked" else 0))
b = blocked[-1] if blocked else {}
for k in ("udp", "icmp", "other", "ipv6"):
    print("%s=%d" % (k, b.get("blocked", {}).get(k, {}).get("packets", -1)))
print("berror=%s" % b.get("error", ""))
PY
)"
  fact() { grep "^$1=" <<<"$facts" | cut -d= -f2-; }
  note "ports seen: $(fact ports)"
  [[ "$(fact port22)" -ge 1 ]] && pass "tcp/22 connection logged ($(fact port22) record(s))" || fail "no record with dst_port 22"
  [[ "$(fact provider)" -ge 1 ]] && pass "provider traffic logged (*.anthropic.com)" || note "no *.anthropic.com record (fine with a non-Anthropic provider)"
  [[ "$(fact blocked_last)" -eq 1 ]] && pass "last record is the blocked record" || fail "no blocked record at the end of the log"
  note "blocked packets: udp=$(fact udp) icmp=$(fact icmp) other=$(fact other) ipv6=$(fact ipv6)"
  [[ -z "$(fact berror)" ]] && pass "all counters read" || fail "counter error: $(fact berror)"
  [[ "$(fact udp)" -ge 2 ]] && pass "UDP probes counted (udp=$(fact udp))" || fail "expected udp >= 2, got $(fact udp)"
  if [[ "$(probe icmp_ping error)" == *"errno 13"* ]]; then
    skip "icmp counter (no ping socket for the agent)"
  else
    [[ "$(fact icmp)" -ge 1 ]] && pass "ICMP probe counted (icmp=$(fact icmp))" || fail "expected icmp >= 1, got $(fact icmp)"
  fi
  base="$(basename "$log" .jsonl)"; sum="$(dirname "$log")/summary-${base#session-}.txt"
  grep -q '^Blocked (packets):' "$sum" 2>/dev/null && pass "summary: $(grep '^Blocked' "$sum")" || fail "summary has no Blocked line ($sum)"
else
  fail "no log under $AUDIT_ROOT/net-*/ — see $WORK/net.out"
fi

step "3b. The chain verifies against the head printed at session end" \
     "the blocked record is chained like any other line."
head_hash="$(grep -o 'head sha256:[0-9a-f]\{64\}' "$WORK/net.out" | tail -1 | cut -d: -f2)"
if [[ -n "$log" && -n "$head_hash" ]]; then
  out="$("${VERIFY[@]}" "$log" "$head_hash")" && pass "verify: $out" || fail "verify: $out"
else
  fail "no head hash in $WORK/net.out — finalize didn't print one"
fi

step "4. Nothing left behind" "compose down at exit removes the session's containers and networks."
left_c="$(docker ps -a --format '{{.Names}}' | grep -E '^(smoke-net|trigon-smoke-net-)' || true)"
left_n="$(docker network ls --format '{{.Name}}' | grep '^trigon-smoke-net-' || true)"
[[ -z "$left_c" ]] && pass "no smoke containers left" || { fail "leftover containers:"; note "$left_c"; }
[[ -z "$left_n" ]] && pass "no smoke networks left"   || { fail "leftover networks:";   note "$left_n"; }

# ── Result ────────────────────────────────────────────────────────────────────
printf '\n%s━━ Result: %d passed, %d failed, %d skipped%s\n' "$B" "$PASSES" "$FAILS" "$SKIPS" "$N"
printf '   session output: %s/net.out   gateway rules: %s/gw-rules.txt   probes: %s\n' "$WORK" "$WORK" "$PJ"
[[ $FAILS -eq 0 ]]
