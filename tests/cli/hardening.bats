#!/usr/bin/env bats
#
# Quick-win hardening controls from docs/threat-model.md:
#   G1 mount deny-list (+ symlink resolution, --allow-unsafe-mount override)
#   G3 cloud-metadata guard under --playwright (--allow-metadata override)
#   G7 runtime hardening defaults in compose/base.yml, --root cap add-back
# None of these need Docker.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TRIGON="$REPO/trigon-up.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export CLAUDE_SETTINGS_DIR="$BATS_TEST_TMPDIR/settings"
}

# ── G1: mount deny-list ───────────────────────────────────────────────────────

@test "mounting /etc is refused" {
  run "$TRIGON" /etc --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to mount"* ]]
  [[ "$output" == *"--allow-unsafe-mount"* ]]
}

@test "mounting the home directory is refused" {
  HOME="$BATS_TEST_TMPDIR" run "$TRIGON" "$BATS_TEST_TMPDIR" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"your home directory"* ]]
}

@test "a symlink to a denied directory is resolved and refused" {
  ln -s /etc "$BATS_TEST_TMPDIR/innocent-looking"
  run "$TRIGON" "$BATS_TEST_TMPDIR/innocent-looking" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to mount"* ]]
}

@test "credential directories under \$HOME are refused" {
  mkdir -p "$BATS_TEST_TMPDIR/.ssh"
  HOME="$BATS_TEST_TMPDIR" run "$TRIGON" "$BATS_TEST_TMPDIR/.ssh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"credential directory"* ]]
}

@test "--allow-unsafe-mount overrides the deny-list with a warning" {
  run "$TRIGON" /etc --allow-unsafe-mount --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: mounting /etc"* ]]
  [[ "$output" == *"[dry-run] would run:"* ]]
}

@test "an ordinary project directory is not affected" {
  run "$TRIGON" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing to mount"* ]]
}

# ── G3: cloud metadata guard ──────────────────────────────────────────────────

@test "--playwright is refused when the metadata service is reachable" {
  TRIGON_METADATA_PROBE=reachable run "$TRIGON" "$PROJ" --playwright --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"169.254.169.254"* ]]
  [[ "$output" == *"--allow-metadata"* ]]
}

@test "--allow-metadata overrides the metadata guard" {
  TRIGON_METADATA_PROBE=reachable run "$TRIGON" "$PROJ" --playwright --allow-metadata --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would run:"* ]]
}

@test "--playwright proceeds (with a loud warning) when metadata is unreachable" {
  TRIGON_METADATA_PROBE=unreachable run "$TRIGON" "$PROJ" --playwright --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOST networking"* ]]
  [[ "$output" == *"[dry-run] would run:"* ]]
}

# ── G7: runtime hardening defaults ────────────────────────────────────────────

@test "base.yml drops all capabilities and forbids privilege escalation" {
  grep -q "no-new-privileges:true" "$REPO/compose/base.yml"
  grep -q "cap_drop:" "$REPO/compose/base.yml"
  grep -qE "^\s+- ALL$" "$REPO/compose/base.yml"
}

@test "base.yml applies resource limits with TRIGON_* overrides" {
  grep -q "pids_limit:" "$REPO/compose/base.yml"
  grep -q "TRIGON_MEM_LIMIT" "$REPO/compose/base.yml"
  grep -q "TRIGON_CPUS" "$REPO/compose/base.yml"
}

@test "--root restores baseline capabilities via a compose fragment" {
  run "$TRIGON" "$PROJ" --root --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline file/uid capabilities restored"* ]]
}
