#!/usr/bin/env python3
"""Summarize a Trigon `--audit` JSON Lines log into a human-readable report.

Usage:
    audit_summary.py LOGFILE [OUTFILE]
    audit_summary.py --verify LOGFILE [HEAD]

Reads the JSONL audit log written by the audit gateway (schema v2, see
docs/audit-design.md §5) and emits a session summary: hash-chain status and
head, unique destinations by request count, total bytes, first/last
timestamps, and decrypted-vs-metadata counts. An empty log yields an explicit
zero-egress statement (FR-9). With OUTFILE, the summary goes to that file and a
one-line chain status goes to stdout (trigon-up.sh prints it); the exit status
is 1 if the chain does not verify.

--verify checks only the hash chain. Given HEAD (the head hash trigon-up.sh
printed at session end), it also fails if the log's head differs — the only way
to catch lines cut off the end, or a log rewritten wholesale with a recomputed
chain (§5.4).

Stdlib only — Trigon requires just a stock python3 on the host (mirrors
lib/parse_provider.py). The parser tolerates malformed/partial lines (an audit
log may be truncated if a session is killed) by skipping them rather than
failing, so a best-effort summary is always produced.

Importable: parse_log(), summarize(), and format_summary() are pure and are the
unit under test in tests/test_audit_summary.py.
"""
import hashlib
import json
import sys

SCHEMA_VERSION = 2
# `prev` of the first record. Must match compose/audit/audit_addon.py.
GENESIS = "0" * 64


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


def line_hash(line):
    """sha256 of one log line as written (without its newline)."""
    return hashlib.sha256(line.encode("utf-8")).hexdigest()


def verify_chain(text):
    """Check the v2 hash chain over the raw log text.

    Returns {"ok", "records", "head", "error", "line"}. "head" is the hash of
    the last line (GENESIS for an empty log); "line" is the 1-based line of the
    first failure. Unlike parse_log this is strict: a blank, malformed,
    unchained or unterminated line fails, since any of them can hide an edit.
    """
    result = {"ok": True, "records": 0, "head": GENESIS, "error": None, "line": None}

    def fail(lineno, error):
        result.update(ok=False, error=error, line=lineno)
        return result

    if not text:
        return result
    lines = text.split("\n")
    if lines[-1] != "":
        return fail(len(lines), "final line is not newline-terminated (truncated write?)")
    prev = GENESIS
    for lineno, line in enumerate(lines[:-1], 1):
        try:
            rec = json.loads(line)
        except ValueError:
            return fail(lineno, "not valid JSON")
        if not isinstance(rec, dict):
            return fail(lineno, "not a JSON object")
        if rec.get("v") != SCHEMA_VERSION or "prev" not in rec:
            return fail(lineno, "not a v%d chained record" % SCHEMA_VERSION)
        if rec["prev"] != prev:
            return fail(lineno, "prev does not match the hash of the line before it")
        prev = line_hash(line)
        result["records"] = lineno
    result["head"] = prev
    return result


def _chain_status(chain):
    if chain["ok"]:
        return "verified — %d records, head sha256:%s" % (chain["records"], chain["head"])
    return "BROKEN at line %d: %s" % (chain["line"], chain["error"])


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


def format_summary(summary, chain=None):
    """Render a summary dict (and optional verify_chain result) as a report."""
    lines = ["Trigon audit — session summary", "=" * 34]
    if chain is not None:
        lines.append("Hash chain:          %s" % _chain_status(chain))

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


def _read(log_path):
    try:
        # newline="" keeps the line endings exactly as written, for hashing.
        with open(log_path, encoding="utf-8", newline="") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""  # No log written (e.g. gateway saw nothing) → zero-egress.


def main(argv):
    usage = ("Usage: audit_summary.py LOGFILE [OUTFILE]\n"
             "       audit_summary.py --verify LOGFILE [HEAD]\n")
    if len(argv) < 2 or (argv[1] == "--verify" and len(argv) < 3):
        sys.stderr.write(usage)
        return 2

    if argv[1] == "--verify":
        chain = verify_chain(_read(argv[2]))
        if chain["ok"] and len(argv) > 3:
            expected = argv[3].lower()
            if expected.startswith("sha256:"):
                expected = expected[len("sha256:"):]
            if chain["head"] != expected:
                sys.stdout.write(
                    "MISMATCH — chain is intact but its head sha256:%s is not the "
                    "recorded head sha256:%s (lines removed from the end, or the log "
                    "was rewritten)\n" % (chain["head"], expected))
                return 1
        sys.stdout.write(_chain_status(chain) + "\n")
        return 0 if chain["ok"] else 1

    text = _read(argv[1])
    chain = verify_chain(text)
    report = format_summary(summarize(parse_log(text)), chain)

    if len(argv) > 2:
        with open(argv[2], "w", encoding="utf-8") as out:
            out.write(report)
        sys.stdout.write(_chain_status(chain) + "\n")
    else:
        sys.stdout.write(report)
    return 0 if chain["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
