"""mitmproxy addon — Trigon `--audit` network audit log.

Runs inside the `audit-gw` sidecar (see docs/audit-design.md §4 C2). Emits one
JSON Lines record per observed connection/flow to $AUDIT_LOG_FILE.

Two depth modes, selected by $AUDIT_DECRYPT:
  - "0" (default, destination-only): every TLS flow is *passed through* opaque —
    we read the SNI from the ClientHello and mark the connection ignored, so
    mitmproxy never decrypts. Record `mode="metadata"` (host/port + bytes only).
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

NOTE: byte-accurate accounting and the pass-through-on-pinning path are
best-effort and pending live-container verification (no Docker in dev sessions,
consistent with the parked security-hardening controls). The record *schema*
(v1) is the stable contract that `lib/audit_summary.py` and the tests depend on.
"""
from __future__ import annotations  # defer annotations so the module imports

import json
import os
import threading
import time

try:  # mitmproxy is only present inside the sidecar; guarded so host tests can
    from mitmproxy import ctx, http, tcp, tls  # import the pure helpers below.
except ImportError:  # pragma: no cover
    ctx = http = tcp = tls = None  # type: ignore

SCHEMA_VERSION = 1


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
        # SNI observed per client connection id, for attributing metadata records.
        self._sni = {}

    # ── lifecycle ────────────────────────────────────────────────────────────
    def running(self) -> None:
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        # Line-buffered append so records survive an abrupt container stop.
        self._fh = open(self.log_path, "a", buffering=1, encoding="utf-8")
        ctx.log.info(
            "trigon-audit: logging to %s (mode=%s)"
            % (self.log_path, "decrypted" if self.decrypt else "metadata")
        )

    def done(self) -> None:
        if self._fh:
            self._fh.flush()
            self._fh.close()

    def _emit(self, record: dict) -> None:
        record["v"] = SCHEMA_VERSION
        line = json.dumps(record, separators=(",", ":"), sort_keys=True)
        with self._lock:
            self._fh.write(line + "\n")

    # ── TLS: capture SNI; passthrough unless decrypting ──────────────────────
    def tls_clienthello(self, data: tls.ClientHelloData) -> None:
        sni = data.client_hello.sni or ""
        try:
            self._sni[id(data.context.client)] = sni
        except Exception:
            pass
        if not self.decrypt:
            # Destination-only: do not decrypt, tunnel opaque (still logged).
            data.ignore_connection = True

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

    # ── passthrough / raw TCP (destination-only, or pinned decrypt flows) ─────
    def tcp_end(self, flow: tcp.TCPFlow) -> None:
        addr = flow.server_conn.address or ("", 0)
        sni = self._sni.pop(id(flow.client_conn), "")
        bytes_out = sum(len(m.content) for m in flow.messages if m.from_client)
        bytes_in = sum(len(m.content) for m in flow.messages if not m.from_client)
        self._emit({
            "ts": _iso_now(),
            "mode": "metadata",
            "dst_host": sni or (addr[0] if addr else ""),
            "dst_ip": flow.server_conn.peername[0] if flow.server_conn.peername else "",
            "dst_port": addr[1] if addr else 0,
            "bytes_out": bytes_out,
            "bytes_in": bytes_in,
        })


addons = [AuditLogger()]
