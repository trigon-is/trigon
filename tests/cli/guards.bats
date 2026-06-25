#!/usr/bin/env bats
#
# Validation guards in trigon-up.sh that must reject bad input and exit 1
# *before* launching a container. None of these need Docker.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TRIGON="$REPO/trigon-up.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export CLAUDE_SETTINGS_DIR="$BATS_TEST_TMPDIR/settings"
}

@test "unknown provider is rejected and lists available providers" {
  run "$TRIGON" "$PROJ" --provider nonesuch --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown provider"* ]]
  [[ "$output" == *"anthropic"* ]]
}

@test "--air-gap with a direct (internet) provider is rejected" {
  run "$TRIGON" "$PROJ" --provider anthropic --air-gap --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a local provider"* ]]
}

@test "--air-gap and --playwright are incompatible" {
  # Use a direct provider so the air-gap/playwright guard fires (a litellm
  # provider would trip the separate playwright+sidecar guard first).
  run "$TRIGON" "$PROJ" --provider anthropic --air-gap --playwright --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--air-gap and --playwright are incompatible"* ]]
}

@test "--mcp cannot be combined with --air-gap" {
  run "$TRIGON" "$PROJ" --provider ollama --air-gap --mcp foo=http://x/mcp/ --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"--mcp cannot be combined with --air-gap"* ]]
}

@test "opencode rejects non-dev modes" {
  run "$TRIGON" "$PROJ" --agent opencode --mode security --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"only supports --mode dev"* ]]
}

@test "unknown agent is rejected" {
  run "$TRIGON" "$PROJ" --agent bogus --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown agent"* ]]
}

@test "a flag that needs a value errors when it is missing" {
  run "$TRIGON" "$PROJ" --provider
  [ "$status" -eq 1 ]
  [[ "$output" == *"--provider requires a value"* ]]
}

@test "a nonexistent project directory is rejected" {
  run "$TRIGON" /no/such/dir --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Directory not found"* ]]
}

@test "more than 5 project directories is rejected" {
  run "$TRIGON" "$PROJ" "$PROJ" "$PROJ" "$PROJ" "$PROJ" "$PROJ" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Maximum 5"* ]]
}
