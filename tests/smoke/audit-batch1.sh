#!/usr/bin/env bash
# pass/fail/skip always return 0, so `cond && pass … || fail …` is a safe
# if/else here; the backticks in the prompt are literal text for the agent.
# shellcheck disable=SC2015,SC2016
# Host smoke test for M7 --audit Batch 1 (1a guards, 1b per-session compose
# project, 1c log location + hash chain). Needs Docker, so run it on the host,
# from anywhere:
#
#   tests/smoke/audit-batch1.sh            # everything, asks before the sudo check
#   tests/smoke/audit-batch1.sh --no-sudo  # skip the uid-0 check
#
# Safe next to a running Trigon session: it only starts containers named
# smoke-a / smoke-b in their own trigon-smoke-* compose projects, uses its own
# settings dir (~/.trigon-settings-smoke), and works in /tmp/trigon-smoke.
# It never stops or removes anything it didn't start.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRIGON="$REPO/trigon-up.sh"
VERIFY=(python3 "$REPO/lib/audit_summary.py" --verify)
WORK=/tmp/trigon-smoke
SMOKE_SETTINGS="${SMOKE_SETTINGS:-$HOME/.trigon-settings-smoke}"
AUDIT_ROOT="${TRIGON_AUDIT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/trigon/audit}"
ASK_SUDO=1
[[ "${1:-}" == "--no-sudo" ]] && ASK_SUDO=0

PASSES=0; FAILS=0; SKIPS=0
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s━━ %s%s\n' "$B" "$1" "$N"; printf '   why: %s\n' "$2"; }
pass() { printf '   %sPASS%s %s\n' "$G" "$N" "$1"; PASSES=$((PASSES+1)); }
fail() { printf '   %sFAIL%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS+1)); }
skip() { printf '   %sSKIP%s %s\n' "$Y" "$N" "$1"; SKIPS=$((SKIPS+1)); }
note() { printf '        %s\n' "$1"; }

# ── 0. Preflight ──────────────────────────────────────────────────────────────
step "0. Preflight" "the sessions below need Docker, the gateway image and a logged-in agent."
[[ "$(id -u)" -ne 0 ]] || { fail "run this as your normal user, not root"; exit 1; }
command -v docker >/dev/null || { fail "docker not found — run this on the Docker host"; exit 1; }
if ! docker image inspect trigon-audit-gw:latest >/dev/null 2>&1; then
  note "gateway image missing — building it (./build.sh --audit-gateway)"
  "$REPO/build.sh" --audit-gateway || { fail "gateway image build failed"; exit 1; }
fi
pass "docker + trigon-audit-gw:latest present"

AUTH_ARGS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_ARGS=(--api)
  pass "using ANTHROPIC_API_KEY for the smoke sessions"
elif [[ -f "$SMOKE_SETTINGS/.claude/.credentials.json" ]]; then
  pass "using the smoke login in $SMOKE_SETTINGS"
else
  fail "no login for the smoke sessions yet. Do this once, then re-run this script:"
  note "  CLAUDE_SETTINGS_DIR=$SMOKE_SETTINGS $TRIGON $WORK/a --name smoke-login"
  note "  (inside: type /login, finish the browser login, then /exit)"
  note "A separate login keeps the smoke sessions from refreshing — and possibly"
  note "invalidating — the OAuth token of the Trigon session you're working in."
  mkdir -p "$WORK/a"
  exit 1
fi

if ! rm -rf "$WORK" 2>/dev/null; then
  fail "$WORK holds files your user can't delete (left by an earlier sudo/root run)."
  note "Remove it, then re-run this script:  sudo rm -rf $WORK"
  exit 1
fi
mkdir -p "$WORK/a" "$WORK/b"
printf '%s\n' 'Run `curl -sI https://example.com` and `curl -sI https://github.com` and report the status lines.' > "$WORK/prompt.md"

# ── 1. Guards (1a) ────────────────────────────────────────────────────────────
step "1a. --audit --root is refused" \
     "a root agent shares uid 0 with the gateway, which is exempt from interception."
out="$(CLAUDE_SETTINGS_DIR="$WORK/settings-root" "$TRIGON" "$WORK/a" --audit --root 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"--audit and --root are incompatible"* ]]; then
  pass "refused (exit 1)"
else
  fail "expected exit 1 + refusal, got exit $rc"; note "$out"
fi

step "1b. --audit as the root user is refused" \
     "same hole when the host user is uid 0 (e.g. CI). Needs sudo, so it asks first."
if [[ $ASK_SUDO -eq 1 ]] && { read -r -p "   run 'sudo trigon-up.sh --audit' now? [y/N] " a; [[ "$a" == [yY]* ]]; }; then
  out="$(sudo CLAUDE_SETTINGS_DIR="$WORK/settings-root" "$TRIGON" "$WORK/a" --audit 2>&1)"; rc=$?
  if [[ $rc -eq 1 && "$out" == *"host user is root"* ]]; then
    pass "refused (exit 1)"
  else
    fail "expected exit 1 + refusal, got exit $rc"; note "$out"
  fi
  sudo rm -rf "$WORK/settings-root"
else
  skip "uid-0 check (covered by the bats suite with a fake id)"
fi

# ── 2. Two concurrent sessions (1b) ───────────────────────────────────────────
step "2. Two --audit sessions at the same time" \
     "each launch gets its own compose project, so the gateways must not collide."
note "starting smoke-a and smoke-b in the background (output: $WORK/a.out, $WORK/b.out)…"
launch() {
  CLAUDE_SETTINGS_DIR="$SMOKE_SETTINGS" "$TRIGON" "$WORK/$1" --name "smoke-$1" --audit --yolo \
    --prompt-file "$WORK/prompt.md" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} </dev/null >"$WORK/$1.out" 2>&1
}
launch a & PID_a=$!
launch b & PID_b=$!

seen_a=""; seen_b=""; projects=""
for _ in $(seq 1 90); do
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  [[ -z "$seen_a" ]] && seen_a="$(grep -m1 '^trigon-smoke-a-.*audit-gw' <<<"$names")"
  [[ -z "$seen_b" ]] && seen_b="$(grep -m1 '^trigon-smoke-b-.*audit-gw' <<<"$names")"
  [[ -z "$projects" && -n "$seen_a" && -n "$seen_b" ]] && \
    projects="$(docker compose ls --format json 2>/dev/null | grep -o '"Name":"trigon-smoke-[^"]*"' | wc -l | tr -d ' ')"
  [[ -n "$seen_a" && -n "$seen_b" ]] && break
  kill -0 "$PID_a" 2>/dev/null || kill -0 "$PID_b" 2>/dev/null || break
  sleep 2
done
if [[ -n "$seen_a" && -n "$seen_b" ]]; then
  pass "two separate gateways ran side by side:"; note "$seen_a"; note "$seen_b"
  [[ "${projects:-0}" -ge 2 ]] && pass "docker compose ls shows $projects trigon-smoke-* projects" \
                               || note "(docker compose ls didn't list both; the gateway names above are the real check)"
else
  fail "did not see both gateways running (a='${seen_a:-none}' b='${seen_b:-none}')"
fi

note "waiting for both sessions to finish…"
wait "$PID_a"; rc_a=$?; wait "$PID_b"; rc_b=$?
note "session exit codes: smoke-a=$rc_a smoke-b=$rc_b (non-zero is ok here if the agent itself failed)"

step "2b. Nothing left behind" "compose down at exit should remove each session's containers and networks."
left_c="$(docker ps -a --format '{{.Names}}' | grep -E '^(smoke-[ab]|trigon-smoke-)' || true)"
left_n="$(docker network ls --format '{{.Name}}' | grep '^trigon-smoke-' || true)"
[[ -z "$left_c" ]] && pass "no smoke containers left" || { fail "leftover containers:"; note "$left_c"; }
[[ -z "$left_n" ]] && pass "no smoke networks left"   || { fail "leftover networks:";   note "$left_n"; }

# ── 3. Log location + hash chain (1c) ─────────────────────────────────────────
step "3. Logs land outside the project, read-only" \
     "a later agent mounting the project must not be able to reach or edit the log."
for s in a b; do
  [[ -e "$WORK/$s/audit-log" ]] && fail "$WORK/$s/audit-log exists (old location)" \
                                 || pass "no audit-log/ in project $s"
done
logs_a=( "$AUDIT_ROOT"/a-*/session-trigon-smoke-a-*.jsonl )
log_a="${logs_a[${#logs_a[@]}-1]}"
if [[ -f "$log_a" ]]; then
  dir_a="$(dirname "$log_a")"
  pass "smoke-a log: $log_a"
  [[ "$(ls -ld "$dir_a")" == drwx------* ]] && pass "log dir is 0700" || fail "log dir mode: $(ls -ld "$dir_a")"
  [[ "$(ls -l "$log_a")" == -r--r--r--* ]] && pass "log file is 0444" || fail "log file mode: $(ls -l "$log_a")"
  ls "$AUDIT_ROOT"/b-*/session-trigon-smoke-b-*.jsonl >/dev/null 2>&1 \
    && pass "smoke-b has its own log under $AUDIT_ROOT/b-*/" || fail "no smoke-b log found"
else
  fail "no smoke-a log under $AUDIT_ROOT/a-*/ — see $WORK/a.out"
  log_a=""
fi

step "3b. The chain verifies against the head printed at session end" \
     "the printed head hash is what makes later edits detectable."
head_a="$(grep -o 'head sha256:[0-9a-f]\{64\}' "$WORK/a.out" | tail -1 | cut -d: -f2)"
records="$(grep -o 'verified — [0-9]* records' "$WORK/a.out" | tail -1 | grep -o '[0-9]*')"
if [[ -n "$log_a" && -n "$head_a" ]]; then
  note "printed head: $head_a ($records records)"
  [[ "${records:-0}" -gt 0 ]] || note "0 records: the agent made no connections — check $WORK/a.out (login?)"
  out="$("${VERIFY[@]}" "$log_a" "$head_a")" && pass "verify: $out" || fail "verify: $out"

  step "3c. Tampering is detected (on copies, the real log is untouched)" \
       "an edited line or a cut-off tail must fail verification against the head."
  cp "$log_a" "$WORK/edited.jsonl"; chmod u+w "$WORK/edited.jsonl"
  sed -i.bak '1s/"bytes_out":[0-9]*/"bytes_out":999999/' "$WORK/edited.jsonl"
  if [[ "${records:-0}" -eq 0 ]]; then
    skip "edit/truncate demo needs at least one record"
  else
    out="$("${VERIFY[@]}" "$WORK/edited.jsonl" "$head_a")" && fail "edit not detected: $out" || pass "edited line detected: $out"
    sed '$d' "$log_a" > "$WORK/truncated.jsonl"
    out="$("${VERIFY[@]}" "$WORK/truncated.jsonl" "$head_a")" && fail "truncation not detected: $out" || pass "cut-off last line detected: $out"
  fi
else
  fail "no head hash in $WORK/a.out — finalize didn't print one"
fi

step "3d. The audit dir can't be mounted into a container" "it is on the G1 mount deny-list."
out="$("$TRIGON" "$AUDIT_ROOT" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"audit log directory"* ]] && pass "mount refused (exit 1)" || { fail "expected refusal, got exit $rc"; note "$out"; }

# ── Result ────────────────────────────────────────────────────────────────────
printf '\n%s━━ Result: %d passed, %d failed, %d skipped%s\n' "$B" "$PASSES" "$FAILS" "$SKIPS" "$N"
printf '   session output: %s/a.out %s/b.out\n' "$WORK" "$WORK"
[[ $FAILS -eq 0 ]]
