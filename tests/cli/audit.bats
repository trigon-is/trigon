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
# post-session path (finalize + teardown) runs without a real Docker.
stub_docker() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF2'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
case "$*" in
  *" run --rm "*) exit 3 ;;
esac
exit 0
EOF2
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
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
