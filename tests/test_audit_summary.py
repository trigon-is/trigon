#!/usr/bin/env python3
"""Unit + property-based tests for the --audit log serializer/parser.

Covers lib/audit_summary.py (host-side summary) and the pure redaction helper in
compose/audit/audit_addon.py. Property-based cases use the stdlib `random` module
only — Trigon requires just a stock python3, no pip packages (mirrors the rest of
tests/). PBT rules PBT-02/03/07/08/09 (round-trip, malformed-input robustness,
serializer/parser invariants) are the enforced targets.

Run: python3 -m unittest discover -s tests
"""
import json
import random
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "lib"))
sys.path.insert(0, str(REPO / "compose" / "audit"))

import audit_summary  # noqa: E402
import audit_addon    # noqa: E402


def make_record(rng, mode=None):
    """Generate a schema-v1-shaped record the way the gateway addon would."""
    host = rng.choice(["api.anthropic.com", "github.com", "example.org", ""])
    mode = mode or rng.choice(["metadata", "decrypted"])
    rec = {
        "v": 1,
        "ts": "2026-08-15T10:%02d:%02d.000Z" % (rng.randint(0, 59), rng.randint(0, 59)),
        "mode": mode,
        "dst_host": host,
        "dst_ip": "203.0.113.%d" % rng.randint(1, 254),
        "dst_port": rng.choice([80, 443, 4000]),
        "bytes_out": rng.randint(0, 10000),
        "bytes_in": rng.randint(0, 100000),
    }
    if mode == "decrypted":
        rec["method"] = rng.choice(["GET", "POST"])
        rec["path"] = rng.choice(["/v1/messages", "/repos/x/y"])
        rec["status"] = rng.choice([200, 404, 500])
    return rec


def serialize(records):
    return "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records)


class TestSummaryUnit(unittest.TestCase):
    def test_empty_log_is_zero_egress(self):
        report = audit_summary.format_summary(audit_summary.summarize([]))
        self.assertIn("0 outbound requests", report)
        self.assertIn("zero-egress", report)

    def test_basic_aggregation(self):
        recs = [
            {"ts": "2026-08-15T10:00:00.000Z", "mode": "metadata",
             "dst_host": "api.anthropic.com", "dst_port": 443,
             "bytes_out": 100, "bytes_in": 200},
            {"ts": "2026-08-15T10:00:01.000Z", "mode": "decrypted",
             "dst_host": "api.anthropic.com", "dst_port": 443,
             "bytes_out": 50, "bytes_in": 75},
            {"ts": "2026-08-15T10:00:02.000Z", "mode": "metadata",
             "dst_host": "github.com", "dst_port": 443,
             "bytes_out": 10, "bytes_in": 20},
        ]
        s = audit_summary.summarize(recs)
        self.assertEqual(s["total_requests"], 3)
        self.assertEqual(s["unique_destinations"], 2)
        self.assertEqual(s["total_bytes_out"], 160)
        self.assertEqual(s["total_bytes_in"], 295)
        self.assertEqual(s["decrypted"], 1)
        self.assertEqual(s["metadata"], 2)
        self.assertEqual(s["first_ts"], "2026-08-15T10:00:00.000Z")
        self.assertEqual(s["last_ts"], "2026-08-15T10:00:02.000Z")

    def test_ranking_by_count_then_host(self):
        report = audit_summary.format_summary(audit_summary.summarize([
            {"mode": "metadata", "dst_host": "b.com", "dst_port": 443},
            {"mode": "metadata", "dst_host": "a.com", "dst_port": 443},
            {"mode": "metadata", "dst_host": "a.com", "dst_port": 443},
        ]))
        # a.com (2 reqs) must be listed before b.com (1 req).
        self.assertLess(report.index("a.com"), report.index("b.com"))


class TestParserRobustness(unittest.TestCase):
    def test_skips_malformed_lines(self):
        text = (
            '{"mode":"metadata","dst_host":"a.com","dst_port":443}\n'
            "not json at all\n"
            "\n"
            "   \n"
            '{"partial": \n'
            '[1,2,3]\n'            # valid json but not a dict
            '"a string"\n'         # valid json, not a dict
            '{"mode":"metadata","dst_host":"b.com","dst_port":80}\n'
        )
        recs = audit_summary.parse_log(text)
        self.assertEqual(len(recs), 2)

    def test_non_numeric_bytes_do_not_crash(self):
        recs = audit_summary.parse_log(
            '{"mode":"metadata","dst_host":"a.com","bytes_out":"oops","bytes_in":null}\n'
        )
        s = audit_summary.summarize(recs)
        self.assertEqual(s["total_bytes_out"], 0)
        self.assertEqual(s["total_bytes_in"], 0)


class TestPropertyBased(unittest.TestCase):
    """PBT-02/03/07/08/09 — round-trip and robustness invariants."""

    def test_roundtrip_preserves_counts_and_bytes(self):
        rng = random.Random(1234)
        for _ in range(200):
            n = rng.randint(0, 40)
            recs = [make_record(rng) for _ in range(n)]
            parsed = audit_summary.parse_log(serialize(recs))
            self.assertEqual(len(parsed), n)
            s = audit_summary.summarize(parsed)
            self.assertEqual(s["total_requests"], n)
            self.assertEqual(s["total_bytes_out"], sum(r["bytes_out"] for r in recs))
            self.assertEqual(s["total_bytes_in"], sum(r["bytes_in"] for r in recs))
            self.assertEqual(
                s["unique_destinations"],
                len({(r["dst_host"] or r["dst_ip"]) for r in recs}),
            )
            self.assertEqual(
                s["decrypted"], sum(1 for r in recs if r["mode"] == "decrypted"))

    def test_garbage_interleaving_never_raises_and_counts_valid(self):
        rng = random.Random(99)
        garbage = ["", "   ", "{", "}", "null", "12", "not json", "[]", '{"x"']
        for _ in range(200):
            recs = [make_record(rng) for _ in range(rng.randint(0, 20))]
            lines = [json.dumps(r) for r in recs]
            for _ in range(rng.randint(0, 10)):
                lines.insert(rng.randint(0, len(lines)), rng.choice(garbage))
            parsed = audit_summary.parse_log("\n".join(lines) + "\n")
            # Every generated record is a dict and must survive; garbage is dropped.
            self.assertEqual(len(parsed), len(recs))

    def test_summary_is_renderable_for_any_parsed_input(self):
        rng = random.Random(7)
        for _ in range(100):
            recs = [make_record(rng) for _ in range(rng.randint(0, 15))]
            report = audit_summary.format_summary(
                audit_summary.summarize(audit_summary.parse_log(serialize(recs))))
            self.assertIsInstance(report, str)
            self.assertTrue(report.endswith("\n"))


class TestRedaction(unittest.TestCase):
    """NFR-1: query strings (which can carry tokens/keys) are stripped."""

    def test_strip_query_removes_everything_after_question_mark(self):
        self.assertEqual(audit_addon._strip_query("/v1/messages?api_key=SECRET"),
                         "/v1/messages")
        self.assertEqual(audit_addon._strip_query("/plain"), "/plain")
        self.assertEqual(audit_addon._strip_query(""), "")

    def test_iso_timestamp_shape(self):
        ts = audit_addon._iso_now()
        self.assertRegex(ts, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")


if __name__ == "__main__":
    unittest.main()
