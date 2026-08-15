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
