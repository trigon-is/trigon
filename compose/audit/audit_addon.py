"""mitmproxy addon — Trigon `--audit` network audit log.

Runs inside the `audit-gw` sidecar (see docs/audit-design.md §4 C2). Emits one
JSON Lines record per observed connection/flow to $AUDIT_LOG_FILE.

Two depth modes, selected by $AUDIT_DECRYPT:
  - "0" (default, destination-only): every connection is *passed through* opaque
    (`ignore_hosts=.*`), so mitmproxy never decrypts. `show_ignored_hosts` keeps
    the relayed stream visible as a raw TCP flow — without it mitmproxy fires no
    hooks at all for ignored connections and nothing would be logged. We read
    the SNI from the still-plaintext ClientHello and count bytes per direction.
    Record `mode="metadata"` (host/port + bytes only).
  - "1" (--audit-decrypt): flows whose client trusts the session CA are
    intercepted; record `mode="decrypted"` adds method / redacted path / status.
    Flows that refuse the MITM (cert pinning) fall to the decrypt-failure policy:
      * pass-through-SNI (default): tunnel opaque, still logged by destination.
      * fail-closed ($AUDIT_DECRYPT_FAIL_CLOSED="1"): the connection is killed.

Redaction (NFR-1): never records bodies, `Authorization` /
`Proxy-Authorization` headers, API keys, or query-string tokens. The request
path is stored with its query string stripped.

The sidecar runs as uid 0 with cap_drop:ALL + NET_ADMIN + DAC_OVERRIDE; the
DAC_OVERRIDE is what lets root write this log/CA into the host-owned bind mount.

NOTE: the pass-through-on-pinning path (decrypt mode) is best-effort and
pending live-container verification (no Docker in dev sessions,
consistent with the parked security-hardening controls). The record *schema*
(v1) is the stable contract that `lib/audit_summary.py` and the tests depend on.
"""
from __future__ import annotations  # defer annotations so the module imports

import ipaddress
import json
import os
import threading
import time

try:  # mitmproxy is only present inside the sidecar; guarded so host tests can
    from mitmproxy import ctx, http, tcp  # import the pure helpers below.
    from mitmproxy.proxy.layers.tls import parse_client_hello
except ImportError:  # pragma: no cover
    ctx = http = tcp = parse_client_hello = None  # type: ignore

SCHEMA_VERSION = 1
# Stop looking for a ClientHello after this many client bytes (not TLS, or junk).
MAX_HELLO_BYTES = 16384


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + \
        ".%03dZ" % (int(time.time() * 1000) % 1000)


def _strip_query(path: str) -> str:
    """Drop the query string — it can carry tokens/keys (NFR-1)."""
    return path.split("?", 1)[0] if path else path


class AuditLogger:
    def __init__(self) -> None:
        self.log_path = os.environ.get("AUDIT_LOG_FILE", "/audit-log/session.jsonl")
        self.decrypt = os.environ.get("AUDIT_DECRYPT", "0") == "1"
        self.fail_closed = os.environ.get("AUDIT_DECRYPT_FAIL_CLOSED", "0") == "1"
        self._lock = threading.Lock()
        self._fh = None
        # Per raw-TCP flow id: SNI + running byte counts (contents are dropped).
        self._conns = {}
        # Upstream connects started but not yet established/failed, by server id.
        self._pending = {}

    # ── lifecycle ────────────────────────────────────────────────────────────
    def running(self) -> None:
        if not self.decrypt:
            # Destination-only: tunnel everything opaque, but keep the flows
            # observable (tcp_* hooks) so each connection is still logged.
            ctx.options.update(ignore_hosts=[".*"], show_ignored_hosts=True)
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        # Line-buffered append so records survive an abrupt container stop.
        self._fh = open(self.log_path, "a", buffering=1, encoding="utf-8")
        ctx.log.info(
            "trigon-audit: logging to %s (mode=%s)"
            % (self.log_path, "decrypted" if self.decrypt else "metadata")
        )

    def done(self) -> None:
        if self._fh:
            # Connections still open at shutdown would otherwise go unrecorded.
            for state in list(self._conns.values()):
                self._emit_tcp(state["flow"])
            for server in list(self._pending.values()):
                self._emit_attempt(server, "unresolved at shutdown")
            self._fh.flush()
            self._fh.close()

    def _emit(self, record: dict) -> None:
        record["v"] = SCHEMA_VERSION
        line = json.dumps(record, separators=(",", ":"), sort_keys=True)
        with self._lock:
            self._fh.write(line + "\n")

    # ── intercepted HTTP (decrypt path only) ─────────────────────────────────
    def response(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        self._emit({
            "ts": _iso_now(),
            "mode": "decrypted",
            "dst_host": req.pretty_host or "",
            "dst_ip": flow.server_conn.peername[0] if flow.server_conn.peername else "",
            "dst_port": req.port,
            "bytes_out": len(req.raw_content or b""),
            "bytes_in": len(flow.response.raw_content or b"") if flow.response else 0,
            "method": req.method,
            "path": _strip_query(req.path),
            "status": flow.response.status_code if flow.response else 0,
        })

    def error(self, flow: http.HTTPFlow) -> None:
        # An intercepted flow that errored (e.g. handshake refused). Still record
        # the destination so completeness holds; content stays unknown.
        req = getattr(flow, "request", None)
        if req is None:
            return
        self._emit({
            "ts": _iso_now(),
            "mode": "metadata",
            "dst_host": req.pretty_host or "",
            "dst_ip": "",
            "dst_port": req.port,
            "bytes_out": 0,
            "bytes_in": 0,
        })

    # ── passthrough / raw TCP (destination-only, or non-HTTP decrypt flows) ───
    def _state(self, flow: tcp.TCPFlow) -> dict:
        return self._conns.setdefault(flow.id, {
            "flow": flow, "sni": "", "hello": b"", "out": 0, "in": 0,
        })

    def tcp_start(self, flow: tcp.TCPFlow) -> None:
        self._state(flow)

    def tcp_message(self, flow: tcp.TCPFlow) -> None:
        state = self._state(flow)
        msg = flow.messages[-1]
        if msg.from_client:
            state["out"] += len(msg.content)
            if state["hello"] is not None:
                # The ClientHello is plaintext even when we do not decrypt.
                state["hello"] += msg.content
                try:
                    hello = parse_client_hello(state["hello"])
                except ValueError:
                    hello, state["hello"] = None, None   # not TLS
                if hello is not None:
                    state["sni"], state["hello"] = hello.sni or "", None
                elif state["hello"] and len(state["hello"]) > MAX_HELLO_BYTES:
                    state["hello"] = None
        else:
            state["in"] += len(msg.content)
        # Counted; do not accumulate the relayed payload (memory + NFR-1). The
        # newest message stays: mitmproxy's own dumper reads messages[-1].
        del flow.messages[:-1]

    def _emit_tcp(self, flow: tcp.TCPFlow) -> None:
        state = self._conns.pop(flow.id, None)
        if state is None:
            return
        addr = flow.server_conn.address or ("", 0)
        peer = flow.server_conn.peername
        self._emit({
            "ts": _iso_now(),
            "mode": "metadata",
            "dst_host": state["sni"] or flow.client_conn.sni or addr[0] or "",
            "dst_ip": peer[0] if peer else "",
            "dst_port": addr[1],
            "bytes_out": state["out"],
            "bytes_in": state["in"],
        })

    def tcp_end(self, flow: tcp.TCPFlow) -> None:
        self._emit_tcp(flow)

    def tcp_error(self, flow: tcp.TCPFlow) -> None:
        # Only raised for a failed upstream connect — server_connect_error logs it.
        self._conns.pop(flow.id, None)

    # ── failed connection attempts (both modes) ──────────────────────────────
    # No flow exists when the upstream connect fails — or is still hanging when
    # the session ends — but the attempt is still egress: record where it was
    # headed. Attempts are tracked from the moment mitmproxy starts connecting.
    def server_connect(self, data) -> None:
        if data.server.error:
            # Refused by mitmproxy before any packet left (its self-connect
            # guard, e.g. the healthcheck probing the listener): not egress.
            return
        self._pending[data.server.id] = data.server

    def server_connected(self, data) -> None:
        self._pending.pop(data.server.id, None)   # the flow hooks log it

    def server_connect_error(self, data) -> None:
        self._emit_attempt(data.server, data.server.error or "connect failed")

    def _emit_attempt(self, server, error: str) -> None:
        if self._pending.pop(server.id, None) is None:
            return
        addr = server.address or ("", 0)
        try:
            ipaddress.ip_address(addr[0])
            dst_ip = addr[0]
        except ValueError:
            dst_ip = ""
        self._emit({
            "ts": _iso_now(),
            "mode": "metadata",
            "dst_host": server.sni or addr[0] or "",
            "dst_ip": dst_ip,
            "dst_port": addr[1],
            "bytes_out": 0,
            "bytes_in": 0,
            "error": error,
        })


addons = [AuditLogger()]
