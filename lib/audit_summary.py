#!/usr/bin/env python3
"""Summarize a Trigon `--audit` JSON Lines log into a human-readable report.

Usage:
    audit_summary.py LOGFILE [OUTFILE]

Reads the JSONL audit log written by the audit gateway (schema v1, see
docs/audit-design.md §5) and emits a session summary: unique destinations by
request count, total bytes, first/last timestamps, and decrypted-vs-metadata
counts. An empty log yields an explicit zero-egress statement (FR-9).

Stdlib only — Trigon requires just a stock python3 on the host (mirrors
lib/parse_provider.py). The parser tolerates malformed/partial lines (an audit
log may be truncated if a session is killed) by skipping them rather than
failing, so a best-effort summary is always produced.

Importable: parse_log(), summarize(), and format_summary() are pure and are the
unit under test in tests/test_audit_summary.py.
"""
import json
import sys

SCHEMA_VERSION = 1


def parse_log(text):
    """Parse JSONL text into a list of record dicts, skipping bad lines."""
    records = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(rec, dict):
            continue
        records.append(rec)
    return records


def _to_int(value):
    try:
        return int(value)
    except (ValueError, TypeError):
        return 0


def summarize(records):
    """Aggregate records into a summary dict."""
    dests = {}            # host -> {"count", "bytes_out", "bytes_in", "ports"}
    total_out = total_in = 0
    decrypted = metadata = 0
    timestamps = []

    for rec in records:
        host = rec.get("dst_host") or rec.get("dst_ip") or "(unknown)"
        port = rec.get("dst_port")
        entry = dests.setdefault(
            host, {"count": 0, "bytes_out": 0, "bytes_in": 0, "ports": set()}
        )
        entry["count"] += 1
        b_out = _to_int(rec.get("bytes_out"))
        b_in = _to_int(rec.get("bytes_in"))
        entry["bytes_out"] += b_out
        entry["bytes_in"] += b_in
        if port is not None:
            entry["ports"].add(port)
        total_out += b_out
        total_in += b_in
        if rec.get("mode") == "decrypted":
            decrypted += 1
        else:
            metadata += 1
        ts = rec.get("ts")
        if isinstance(ts, str) and ts:
            timestamps.append(ts)

    timestamps.sort()
    return {
        "total_requests": len(records),
        "unique_destinations": len(dests),
        "destinations": dests,
        "total_bytes_out": total_out,
        "total_bytes_in": total_in,
        "decrypted": decrypted,
        "metadata": metadata,
        "first_ts": timestamps[0] if timestamps else None,
        "last_ts": timestamps[-1] if timestamps else None,
    }


def format_summary(summary):
    """Render a summary dict as a human-readable report string."""
    lines = ["Trigon audit — session summary", "=" * 34]

    if summary["total_requests"] == 0:
        lines.append("0 outbound requests — zero-egress verified.")
        return "\n".join(lines) + "\n"

    lines.append("Total requests:      %d" % summary["total_requests"])
    lines.append("Unique destinations: %d" % summary["unique_destinations"])
    lines.append("Bytes out / in:      %d / %d"
                 % (summary["total_bytes_out"], summary["total_bytes_in"]))
    lines.append("Depth:               %d decrypted, %d metadata-only"
                 % (summary["decrypted"], summary["metadata"]))
    lines.append("First / last:        %s / %s"
                 % (summary["first_ts"] or "-", summary["last_ts"] or "-"))
    lines.append("")
    lines.append("Destinations (by request count):")

    ranked = sorted(
        summary["destinations"].items(),
        key=lambda kv: (-kv[1]["count"], kv[0]),
    )
    for host, d in ranked:
        ports = ",".join(str(p) for p in sorted(d["ports"])) or "-"
        lines.append(
            "  %-40s %5d req  %10d/%-10d B  ports %s"
            % (host, d["count"], d["bytes_out"], d["bytes_in"], ports)
        )
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("Usage: audit_summary.py LOGFILE [OUTFILE]\n")
        return 2
    log_path = argv[1]
    try:
        with open(log_path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        text = ""  # No log written (e.g. gateway saw nothing) → zero-egress.

    report = format_summary(summarize(parse_log(text)))

    if len(argv) > 2:
        with open(argv[2], "w", encoding="utf-8") as out:
            out.write(report)
    else:
        sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
