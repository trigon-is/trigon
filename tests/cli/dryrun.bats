#!/usr/bin/env bats
#
# --dry-run resolves the provider, assembles compose files and env, and prints
# the command that would run — without starting a container. These exercise the
# core launch wiring (provider -> env -> compose) with no Docker required.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TRIGON="$REPO/trigon-up.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export CLAUDE_SETTINGS_DIR="$BATS_TEST_TMPDIR/settings"
}

@test "default anthropic dry-run exits 0 and prints the intended command" {
  run "$TRIGON" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would run:"* ]]
  [[ "$output" == *"compose/base.yml"* ]]
}

@test "anthropic (tier-1 direct) resolves the default model, no proxy" {
  run "$TRIGON" "$PROJ" --provider anthropic --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"anthropic (direct)"* ]]
  [[ "$output" == *"claude-sonnet-4-6"* ]]
  # direct providers must NOT redirect ANTHROPIC_BASE_URL
  [[ "$output" != *"ANTHROPIC_BASE_URL"* ]]
}

@test "deepseek (tier-2 litellm) adds a sidecar fragment and redirects base url" {
  DEEPSEEK_API_KEY=dummy run "$TRIGON" "$PROJ" --provider deepseek --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"deepseek (litellm-proxy)"* ]]
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://litellm:4000"* ]]
  # a second compose fragment beyond base.yml is mounted for the sidecar
  [[ "$output" == *"-f /app/compose/base.yml -f "* ]] || [[ "$output" == *".yml -f "* ]]
}

@test "model alias resolves through model_map" {
  DEEPSEEK_API_KEY=dummy run "$TRIGON" "$PROJ" --provider deepseek:smart --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"deepseek-v4-pro"* ]]
}

@test "litellm provider requires its API key env var" {
  # No DEEPSEEK_API_KEY exported -> requires check fails before launch.
  run "$TRIGON" "$PROJ" --provider deepseek --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires \$DEEPSEEK_API_KEY"* ]]
}

@test "security mode adds the security compose fragment" {
  run "$TRIGON" "$PROJ" --mode security --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose/security.yml"* ]]
}

@test "--name controls the container name" {
  run "$TRIGON" "$PROJ" --name myrun --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name myrun"* ]]
}

@test "an unknown flag warns but does not abort" {
  run "$TRIGON" "$PROJ" --bogus-flag --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "a single project path adds no extra-mounts fragment" {
  run "$TRIGON" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Compose: -f "*"/compose/base.yml"$'\n'* ]]
}

@test "extra project paths add a mounts fragment" {
  mkdir -p "$BATS_TEST_TMPDIR/p2"
  run "$TRIGON" "$PROJ" "$BATS_TEST_TMPDIR/p2" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/p2 → /app_2"* ]]
  [[ "$output" == *"Compose: -f "*"/compose/base.yml -f "* ]]
}

# ── Per-session compose project (-p) ──────────────────────────────────────────
# Every compose call carries -p trigon-<name>-<6 hex>, so concurrent sessions
# get their own networks/sidecars instead of sharing the "compose" project.

@test "dry-run scopes compose to a per-session project" {
  run "$TRIGON" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "docker compose -p trigon-claude-code-"[0-9a-f]{6}" -f " ]]
  [[ "$output" =~ "Compose project: trigon-claude-code-"[0-9a-f]{6} ]]
}

@test "the compose project name is lowercased and sanitized from --name" {
  run "$TRIGON" "$PROJ" --name "My Box.1" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ " -p trigon-my-box-1-"[0-9a-f]{6}" " ]]
}

@test "two launches get different compose projects" {
  run "$TRIGON" "$PROJ" --dry-run
  p1="$(grep -o -- '-p trigon-[a-z0-9_-]*' <<<"$output")"
  run "$TRIGON" "$PROJ" --dry-run
  p2="$(grep -o -- '-p trigon-[a-z0-9_-]*' <<<"$output")"
  [ -n "$p1" ]
  [ "$p1" != "$p2" ]
}

@test "the litellm sidecar path carries -p" {
  DEEPSEEK_API_KEY=dummy run "$TRIGON" "$PROJ" --provider deepseek --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ " -p trigon-claude-code-"[0-9a-f]{6}" -f " ]]
}

@test "the air-gap path carries -p" {
  run "$TRIGON" "$PROJ" --provider ollama --air-gap --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Air-gap: agent container isolated"* ]]
  [[ "$output" =~ " -p trigon-claude-code-"[0-9a-f]{6}" -f " ]]
}

@test "-p coexists with the per-launch /app_2..N mount fragment" {
  mkdir -p "$BATS_TEST_TMPDIR/proj2"
  run "$TRIGON" "$PROJ" "$BATS_TEST_TMPDIR/proj2" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ /app_2"* ]]
  [[ "$output" =~ " -p trigon-claude-code-"[0-9a-f]{6}" -f "[^\ ]*"/base.yml -f "[^\ ]*"trigon."[^\ ]*".yml" ]]
}
