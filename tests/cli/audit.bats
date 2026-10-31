#!/usr/bin/env bats
#
# --audit network audit log: flag wiring and guards in trigon-up.sh. All exercised
# via --dry-run (no Docker): assert on the echoed audit messages, the injected
# env/mounts, an extra compose fragment, and the launch-time refusals.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TRIGON="$REPO/trigon-up.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export CLAUDE_SETTINGS_DIR="$BATS_TEST_TMPDIR/settings"
  # Keep audit logs out of the real ~/.local/state.
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  unset TRIGON_AUDIT_DIR
}

@test "--audit enables the enforced gateway (destination-only by default)" {
  run "$TRIGON" "$PROJ" --audit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit: enforced gateway enabled"* ]]
  [[ "$output" == *"depth: destination-only"* ]]
  # a second compose fragment beyond base.yml is mounted for the gateway
  [[ "$output" == *"-f /app/compose/base.yml -f "* ]] || [[ "$output" == *".yml -f "* ]]
  # default depth injects no CA into the agent
  [[ "$output" != *"NODE_EXTRA_CA_CERTS"* ]]
}

@test "--audit and --playwright are incompatible" {
  run "$TRIGON" "$PROJ" --audit --playwright --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--audit and --playwright are incompatible"* ]]
}

@test "--audit and --root are incompatible (uid-0 agent would bypass the gateway)" {
  run "$TRIGON" "$PROJ" --audit --root --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--audit and --root are incompatible"* ]]
  [[ "$output" == *"threat-model G6"* ]]
  [[ "$output" != *"[dry-run] would run:"* ]]
}

@test "--audit is refused when the host user is root (uid 0)" {
  # Shadow `id` so the launcher sees uid 0 without the test running as root.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/id" <<'EOF'
#!/bin/sh
case "$1" in -u|-g) echo 0 ;; *) exec /usr/bin/id "$@" ;; esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/id"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TRIGON" "$PROJ" --audit --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"host user is root"* ]]
  [[ "$output" == *"threat-model G6"* ]]
  [[ "$output" != *"[dry-run] would run:"* ]]
}

@test "a root host user without --audit is not affected by the audit uid guard" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/id" <<'EOF'
#!/bin/sh
case "$1" in -u|-g) echo 0 ;; *) exec /usr/bin/id "$@" ;; esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/id"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TRIGON" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
}

@test "--audit-decrypt requires --audit" {
  run "$TRIGON" "$PROJ" --audit-decrypt --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"require --audit"* ]]
}

@test "--audit-decrypt-fail-closed requires --audit-decrypt" {
  run "$TRIGON" "$PROJ" --audit --audit-decrypt-fail-closed --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--audit-decrypt-fail-closed requires --audit-decrypt"* ]]
}

@test "--audit-decrypt injects the session CA and reports pass-through-SNI" {
  run "$TRIGON" "$PROJ" --audit --audit-decrypt --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth: decrypt (pass-through-SNI)"* ]]
  [[ "$output" == *"NODE_EXTRA_CA_CERTS=/audit-ca/mitmproxy-ca-cert.pem"* ]]
  [[ "$output" == *"/audit-ca:ro"* ]]
}

@test "--audit-decrypt-fail-closed selects the strict decrypt-failure policy" {
  run "$TRIGON" "$PROJ" --audit --audit-decrypt --audit-decrypt-fail-closed --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth: decrypt (fail-closed)"* ]]
}

@test "--audit-allow-degraded announces fail-open" {
  run "$TRIGON" "$PROJ" --audit --audit-allow-degraded --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fail-open"* ]]
}

@test "--air-gap --audit compose without a network_mode conflict" {
  run "$TRIGON" "$PROJ" --provider ollama --air-gap --audit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Air-gap: agent container isolated"* ]]
  [[ "$output" == *"Audit: enforced gateway enabled"* ]]
}

@test "--audit scopes the gateway to a per-session compose project" {
  run "$TRIGON" "$PROJ" --audit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ " -p trigon-claude-code-"[0-9a-f]{6}" -f " ]]
}

# A stub `docker` that logs every call and makes `compose run` fail, so the
# post-session path (finalize + teardown) runs without a real Docker. On `run`
# it plays the gateway: it finds the sidecar's /audit-log bind in the generated
# fragment and writes a two-record hash-chained log there with the real addon.
stub_docker() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF2'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
case "$*" in
  *" run --rm "*)
    for a in "$@"; do
      case "$a" in *.yml)
        w="$(sed -n 's#^ *- \(.*\):/audit-log$#\1#p' "$a")"
        [ -n "$w" ] && python3 - "$STUB_REPO" "$w/session.jsonl" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/compose/audit")
import audit_addon as a
prev = a.GENESIS
with open(sys.argv[2], "w") as fh:
    for host in ("api.anthropic.com", "github.com"):
        line = a.chain_line({"mode": "metadata", "dst_host": host, "dst_port": 443,
                             "bytes_out": 1, "bytes_in": 2}, prev)
        fh.write(line + "\n")
        prev = a.line_hash(line)
PY
      ;; esac
    done
    exit 3 ;;
esac
exit 0
EOF2
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" STUB_REPO="$REPO"
}

@test "a failed --audit session still exports the log and tears down only its project" {
  stub_docker
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TRIGON" "$PROJ" --audit
  [ "$status" -eq 3 ]                       # the session's exit status is passed on
  [[ "$output" == *"Audit: log + summary written"* ]]
  proj="$(grep -o -- '-p trigon-[a-z0-9_-]*' "$DOCKER_LOG" | head -1)"
  [ -n "$proj" ]
  # finalize stops this session's gateway, then the whole project is taken down
  grep -q -- "compose $proj .* rm --stop --force -v audit-gw" "$DOCKER_LOG"
  grep -q -- "compose $proj .* down -v --remove-orphans" "$DOCKER_LOG"
  [ "$(grep -n 'audit-gw$' "$DOCKER_LOG" | cut -d: -f1)" -lt "$(grep -n 'down -v' "$DOCKER_LOG" | cut -d: -f1)" ]
  # every compose call is scoped to the same project
  [ "$(grep ' compose ' "$DOCKER_LOG" | grep -v ' compose version' | grep -vc -- "$proj")" -eq 0 ]
}

# ── D7: log location, permissions, hash chain ────────────────────────────────

@test "--audit logs to the XDG state dir, not into the project" {
  run "$TRIGON" "$PROJ" --audit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Audit: log will be written to $XDG_STATE_HOME/trigon/audit/proj-"[0-9]+/ ]]
  [[ "$output" != *"$PROJ/audit-log"* ]]
  [ ! -e "$PROJ/audit-log" ]
  [ ! -e "$XDG_STATE_HOME/trigon" ]          # dry-run creates nothing
}

@test "TRIGON_AUDIT_DIR overrides the audit log root" {
  TRIGON_AUDIT_DIR="$BATS_TEST_TMPDIR/elsewhere" run "$TRIGON" "$PROJ" --audit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit: log will be written to $BATS_TEST_TMPDIR/elsewhere/proj-"* ]]
}

@test "same-named projects in different places get different log dirs" {
  mkdir -p "$BATS_TEST_TMPDIR/a/proj" "$BATS_TEST_TMPDIR/b/proj"
  run "$TRIGON" "$BATS_TEST_TMPDIR/a/proj" --audit --dry-run
  d1="$(grep -o 'written to .*' <<<"$output")"
  run "$TRIGON" "$BATS_TEST_TMPDIR/b/proj" --audit --dry-run
  d2="$(grep -o 'written to .*' <<<"$output")"
  [ -n "$d1" ]
  [ "$d1" != "$d2" ]
}

@test "mounting the audit log dir, a subdir or a parent of it is refused (G1)" {
  mkdir -p "$XDG_STATE_HOME/trigon/audit/proj-1"
  for p in "$XDG_STATE_HOME/trigon/audit" "$XDG_STATE_HOME/trigon/audit/proj-1" "$XDG_STATE_HOME"; do
    run "$TRIGON" "$p" --dry-run              # refused with or without --audit
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to mount"* ]]
    [[ "$output" == *"audit log directory"* ]]
  done
  # ...also as an extra project path, and when reached through a symlink
  ln -s "$XDG_STATE_HOME/trigon" "$BATS_TEST_TMPDIR/link"
  run "$TRIGON" "$PROJ" "$BATS_TEST_TMPDIR/link" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"audit log directory"* ]]
}

@test "a session's log lands in the state dir, read-only, with a verifying chain" {
  stub_docker
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TRIGON" "$PROJ" --audit
  [ "$status" -eq 3 ]
  [ ! -e "$PROJ/audit-log" ]
  dir="$(echo "$XDG_STATE_HOME"/trigon/audit/proj-*)"
  [ -d "$dir" ]
  [[ "$(ls -ld "$dir")" == drwx------* ]]
  [[ "$(ls -ld "$XDG_STATE_HOME/trigon/audit")" == drwx------* ]]
  log="$(echo "$dir"/session-trigon-claude-code-*.jsonl)"
  sum="$(echo "$dir"/summary-trigon-claude-code-*.txt)"
  [[ "$(ls -l "$log")" == -r--r--r--* ]]
  [[ "$(ls -l "$sum")" == -r--r--r--* ]]
  # the head hash is printed at session end and matches the log
  [[ "$output" == *"Audit: hash chain verified — 2 records, head sha256:"* ]]
  head="$(grep -o 'head sha256:[0-9a-f]*' <<<"$output" | cut -d: -f2)"
  [ "${#head}" -eq 64 ]
  grep -q "verified — 2 records, head sha256:$head" "$sum"
  run python3 "$REPO/lib/audit_summary.py" --verify "$log" "$head"
  [ "$status" -eq 0 ]
}
