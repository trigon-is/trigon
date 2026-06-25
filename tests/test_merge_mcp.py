#!/usr/bin/env python3
"""Unit tests for lib/merge_mcp.py.

Run: python3 -m unittest discover -s tests
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MERGE = REPO / "lib" / "merge_mcp.py"


def run_merge(path, key, *specs):
    return subprocess.run(
        ["python3", str(MERGE), str(path), key, *specs],
        capture_output=True, text=True,
    )


class TestMergeMcp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, dir="/tmp"
        )
        self.tmp.close()
        self.path = Path(self.tmp.name)
        self.path.unlink()  # start from "no file"

    def tearDown(self):
        if self.path.exists():
            self.path.unlink()

    def load(self):
        return json.loads(self.path.read_text())

    def test_creates_http_entry_on_fresh_file(self):
        r = run_merge(self.path, "", "foo=http://host.docker.internal:8000/mcp/")
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = self.load()
        self.assertEqual(
            cfg["mcpServers"]["foo"],
            {"type": "http", "url": "http://host.docker.internal:8000/mcp/"},
        )

    def test_key_adds_header_without_leaking_secret(self):
        run_merge(self.path, "s3cr3t", "bar=http://h:9000/mcp/")
        entry = self.load()["mcpServers"]["bar"]
        self.assertEqual(
            entry["headers"]["Authorization"], "Bearer ${TRIGON_MCP_KEY}"
        )
        # The real secret must never be written to disk.
        self.assertNotIn("s3cr3t", self.path.read_text())

    def test_merge_preserves_existing_servers(self):
        # e.g. a server already written by --playwright must survive.
        self.path.write_text(json.dumps(
            {"mcpServers": {"playwright": {"type": "stdio", "command": "x"}}}
        ))
        run_merge(self.path, "", "foo=http://h:8000/mcp/")
        servers = self.load()["mcpServers"]
        self.assertIn("playwright", servers)
        self.assertIn("foo", servers)

    def test_multiple_specs_in_one_call(self):
        run_merge(self.path, "", "a=http://h/a/", "b=http://h/b/")
        servers = self.load()["mcpServers"]
        self.assertEqual(set(servers), {"a", "b"})

    def test_malformed_spec_errors(self):
        r = run_merge(self.path, "", "no-equals-sign")
        self.assertEqual(r.returncode, 1)
        self.assertIn("NAME=URL", r.stderr)

    def test_malformed_existing_file_treated_as_empty(self):
        self.path.write_text("{ not valid json")
        r = run_merge(self.path, "", "foo=http://h/mcp/")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("foo", self.load()["mcpServers"])


if __name__ == "__main__":
    unittest.main()
