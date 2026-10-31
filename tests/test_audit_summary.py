#!/usr/bin/env python3
"""Unit + property-based tests for the --audit log serializer/parser.

Covers lib/audit_summary.py (host-side summary) and the pure redaction helper in
compose/audit/audit_addon.py. Property-based cases use the stdlib `random` module
only — Trigon requires just a stock python3, no pip packages (mirrors the rest of
tests/). PBT rules PBT-02/03/07/08/09 (round-trip, malformed-input robustness,
serializer/parser invariants) are the enforced targets, plus the schema-v2 hash
chain: any single-line edit, delete or reorder is detected.

Run: python3 -m unittest discover -s tests
"""
import contextlib
import hashlib
import io
import json
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "lib"))
sys.path.insert(0, str(REPO / "compose" / "audit"))

import audit_summary  # noqa: E402
import audit_addon    # noqa: E402


def make_record(rng, mode=None):
    """Generate a record body the way the gateway addon would (pre-chaining)."""
    host = rng.choice(["api.anthropic.com", "github.com", "example.org", ""])
    mode = mode or rng.choice(["metadata", "decrypted"])
    rec = {
        "v": 2,
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


def chained_lines(records):
    """Serialize records exactly as the addon writes them (v2, hash-chained)."""
    lines, prev = [], audit_addon.GENESIS
    for rec in records:
        line = audit_addon.chain_line(dict(rec), prev)
        lines.append(line)
        prev = audit_addon.line_hash(line)
    return lines


def text_of(lines):
    return "".join(line + "\n" for line in lines)


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


class TestHashChain(unittest.TestCase):
    """Schema v2: each line's `prev` is the sha256 of the line before it."""

    def test_addon_and_verifier_agree_on_constants(self):
        self.assertEqual(audit_addon.GENESIS, audit_summary.GENESIS)
        self.assertEqual(audit_addon.SCHEMA_VERSION, audit_summary.SCHEMA_VERSION)
        self.assertEqual(audit_summary.SCHEMA_VERSION, 2)

    def test_empty_log_verifies_with_genesis_head(self):
        chain = audit_summary.verify_chain("")
        self.assertTrue(chain["ok"])
        self.assertEqual(chain["records"], 0)
        self.assertEqual(chain["head"], audit_summary.GENESIS)

    def test_addon_output_verifies_and_head_is_last_line_hash(self):
        rng = random.Random(5)
        lines = chained_lines([make_record(rng) for _ in range(10)])
        chain = audit_summary.verify_chain(text_of(lines))
        self.assertTrue(chain["ok"], chain)
        self.assertEqual(chain["records"], 10)
        self.assertEqual(chain["head"], hashlib.sha256(lines[-1].encode()).hexdigest())
        self.assertEqual(json.loads(lines[0])["prev"], audit_summary.GENESIS)

    def test_chained_log_still_summarizes(self):
        rng = random.Random(6)
        recs = [make_record(rng) for _ in range(8)]
        s = audit_summary.summarize(audit_summary.parse_log(text_of(chained_lines(recs))))
        self.assertEqual(s["total_requests"], 8)
        self.assertEqual(s["total_bytes_out"], sum(r["bytes_out"] for r in recs))

    def test_summary_reports_chain_status_and_head(self):
        rng = random.Random(8)
        text = text_of(chained_lines([make_record(rng) for _ in range(3)]))
        chain = audit_summary.verify_chain(text)
        report = audit_summary.format_summary(
            audit_summary.summarize(audit_summary.parse_log(text)), chain)
        self.assertIn("verified — 3 records, head sha256:" + chain["head"], report)
        broken = audit_summary.verify_chain(text.replace('"prev":"', '"prev":"f', 1))
        report = audit_summary.format_summary(audit_summary.summarize([]), broken)
        self.assertIn("BROKEN at line 1", report)

    def test_v1_unterminated_and_blank_lines_fail(self):
        rng = random.Random(9)
        lines = chained_lines([make_record(rng) for _ in range(3)])
        v1 = '{"v":1,"mode":"metadata","dst_host":"a.com"}\n'
        self.assertFalse(audit_summary.verify_chain(v1)["ok"])
        self.assertFalse(audit_summary.verify_chain(text_of(lines)[:-1])["ok"])
        self.assertFalse(audit_summary.verify_chain(
            text_of(lines[:1]) + "\n" + text_of(lines[1:]))["ok"])

    def test_tail_hash_resumes_the_chain_across_an_addon_reload(self):
        rng = random.Random(10)
        lines = chained_lines([make_record(rng) for _ in range(4)])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "session.jsonl")
            self.assertEqual(audit_addon.tail_hash(path), audit_addon.GENESIS)
            with open(path, "w") as fh:
                fh.write(text_of(lines[:2]))
            # A reloaded addon continues from the file's last line.
            prev = audit_addon.tail_hash(path)
            with open(path, "a") as fh:
                for rec in (make_record(rng), make_record(rng)):
                    line = audit_addon.chain_line(rec, prev)
                    fh.write(line + "\n")
                    prev = audit_addon.line_hash(line)
            with open(path) as fh:
                chain = audit_summary.verify_chain(fh.read())
            self.assertTrue(chain["ok"], chain)
            self.assertEqual(chain["records"], 4)

    def test_cli_verify_checks_the_recorded_head(self):
        rng = random.Random(11)
        lines = chained_lines([make_record(rng) for _ in range(5)])
        head = audit_addon.line_hash(lines[-1])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "session.jsonl")
            with open(path, "w") as fh:
                fh.write(text_of(lines))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(audit_summary.main(["x", "--verify", path]), 0)
                self.assertEqual(audit_summary.main(["x", "--verify", path, "sha256:" + head]), 0)
            # Cut the last line: the remaining chain is intact, only the head catches it.
            with open(path, "w") as fh:
                fh.write(text_of(lines[:-1]))
            with contextlib.redirect_stdout(out):
                self.assertEqual(audit_summary.main(["x", "--verify", path]), 0)
                self.assertEqual(audit_summary.main(["x", "--verify", path, head]), 1)
            self.assertIn("MISMATCH", out.getvalue())


def _edit_line(rng, line):
    """Return a different version of one log line (a single-line edit)."""
    rec = json.loads(line)
    choice = rng.randrange(4)
    if choice == 0:
        rec["bytes_out"] = rec["bytes_out"] + rng.randint(1, 1000)
    elif choice == 1:
        rec["dst_host"] = rng.choice(["evil.example", "x.test"]) + str(rng.random())
    elif choice == 2:
        rec["prev"] = hashlib.sha256(str(rng.random()).encode()).hexdigest()
    else:
        # Raw byte-level tamper: flip one character anywhere in the line.
        i = rng.randrange(len(line))
        return line[:i] + chr((ord(line[i]) + rng.randint(1, 25)) % 95 + 32) + line[i + 1:]
    return json.dumps(rec, separators=(",", ":"), sort_keys=True)


class TestHashChainProperties(unittest.TestCase):
    """PBT: any single-line edit, delete or reorder is detected.

    "Detected" means the chain fails to verify, or verifies to a head other than
    the one recorded at session end. A change that touches anything but the last
    line must also fail verification on its own, without the recorded head.
    """

    TRIALS = 300

    def _log(self, rng):
        n = rng.randint(1, 25)
        lines = chained_lines([make_record(rng) for _ in range(n)])
        return lines, audit_addon.line_hash(lines[-1])

    def _assert_detected(self, original, mutated, head, internal):
        self.assertNotEqual(original, mutated)
        chain = audit_summary.verify_chain(text_of(mutated))
        self.assertTrue(not chain["ok"] or chain["head"] != head,
                        "undetected mutation: %r" % (mutated,))
        if internal:
            self.assertFalse(chain["ok"], "chain alone missed a mid-log change")

    def test_any_single_line_edit_is_detected(self):
        rng = random.Random(2026)
        for _ in range(self.TRIALS):
            lines, head = self._log(rng)
            i = rng.randrange(len(lines))
            mutated = list(lines)
            mutated[i] = _edit_line(rng, lines[i])
            if mutated[i] == lines[i]:
                continue
            self._assert_detected(lines, mutated, head, internal=i < len(lines) - 1)

    def test_any_single_line_delete_is_detected(self):
        rng = random.Random(2027)
        for _ in range(self.TRIALS):
            lines, head = self._log(rng)
            i = rng.randrange(len(lines))
            mutated = lines[:i] + lines[i + 1:]
            self._assert_detected(lines, mutated, head, internal=i < len(lines) - 1)

    def test_any_reorder_is_detected(self):
        rng = random.Random(2028)
        for _ in range(self.TRIALS):
            lines, head = self._log(rng)
            if len(lines) < 2:
                continue
            i, j = sorted(rng.sample(range(len(lines)), 2))
            mutated = list(lines)
            mutated[i], mutated[j] = mutated[j], mutated[i]
            self._assert_detected(lines, mutated, head, internal=True)

    def test_unmodified_logs_always_verify(self):
        rng = random.Random(2029)
        for _ in range(self.TRIALS):
            lines, head = self._log(rng)
            chain = audit_summary.verify_chain(text_of(lines))
            self.assertTrue(chain["ok"])
            self.assertEqual(chain["head"], head)


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
