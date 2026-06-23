#!/usr/bin/env python3
"""Merge external HTTP MCP server(s) into a project .mcp.json file.

Usage:
    merge_mcp.py MCP_CONFIG_PATH MCP_KEY NAME=URL [NAME=URL ...]

Used by `trigon-up.sh --mcp NAME=URL`. Reads the existing .mcp.json at
MCP_CONFIG_PATH (if any), adds/overwrites an `mcpServers.<name>` entry of type
`http` for each NAME=URL spec, and writes the result back.

If MCP_KEY is non-empty, each added server gets an Authorization header that
references `${TRIGON_MCP_KEY}` rather than the literal secret — the caller
passes the real value into the container via that env var, so the key never
lands in the file on disk.

A malformed or unreadable existing file is treated as empty (the original is
backed up by trigon-up.sh before this runs).
"""
import json
import os
import sys

path, key = sys.argv[1], sys.argv[2]
specs = sys.argv[3:]

cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, OSError):
        cfg = {}

servers = cfg.setdefault("mcpServers", {})
for spec in specs:
    if "=" not in spec:
        sys.stderr.write(f"Error: --mcp expects NAME=URL, got: {spec}\n")
        sys.exit(1)
    name, url = spec.split("=", 1)
    entry = {"type": "http", "url": url}
    if key:
        entry["headers"] = {"Authorization": "Bearer ${TRIGON_MCP_KEY}"}
    servers[name] = entry

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
