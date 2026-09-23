#!/usr/bin/env bats
load '../helpers'

bats_require_minimum_version 1.5.0   # for `run !`

# `clikae cockpit` (#63) marks the tank that STEERS build/review dispatch and
# installs/removes the guard hook (lib/hooks/cockpit-guard.sh) there — see
# lib/commands/cockpit.sh for the design. These tests exercise the STATE +
# settings.json editing; lib/hooks/cockpit-guard.sh itself is covered in
# tests/bats/cockpit-guard.bats.

_guard_installed() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq -e '(.hooks.PreToolUse // []) | any(._clikae == "cockpit-guard")' "$f" >/dev/null 2>&1
}

@test "bare 'clikae cockpit' with nothing set says so" {
  run clikae cockpit
  [ "$status" -eq 0 ]
  [[ "$output" == *"No cockpit set"* ]] || false
}

@test "marking a tank installs the guard and records state" {
  clikae init claude L
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/L: cockpit guard installed"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/L/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/L" ]
  run clikae cockpit
  [ "$output" = "cockpit: claude/L" ]
  # the marker command points at the real guard script, shell-quoted (r5 P3-1)
  jq -e --arg want "'$CLIKAE_LIB/hooks/cockpit-guard.sh'" \
    '(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command) == $want' \
    "$CLIKAE_HOME/profiles/claude/L/settings.json" >/dev/null
}

@test "an install under a path with a space (and a quote) stores a command the shell runs as one word, and it refuses (#63 r5 P3-1)" {
  # codex review: installed from "install with space/lib", the stored command
  # split at the space under `bash -c` and exited 127 — a non-blocking code,
  # so every spawn would have been allowed.
  local prefix="$BATS_TEST_TMPDIR/install with space/it's here"
  mkdir -p "$prefix"
  cp -R "$CLIKAE_TEST_ROOT/bin" "$CLIKAE_TEST_ROOT/lib" "$prefix/"
  clikae init claude L
  run "$prefix/bin/clikae" cockpit claude L
  [ "$status" -eq 0 ]
  local cmd
  cmd="$(jq -r '.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command' "$CLIKAE_HOME/profiles/claude/L/settings.json")"
  run bash -c "printf '%s' '{\"tool_name\":\"Agent\",\"tool_input\":{\"model\":\"sonnet\",\"prompt\":\"review\"}}' | $cmd"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cockpit-guard: refused"* ]] || false
}

@test "an older UNQUOTED guard entry is repaired to the quoted form on the next mark (#63 r5 P3-1)" {
  clikae init claude L
  clikae cockpit claude L
  local f="$CLIKAE_HOME/profiles/claude/L/settings.json"
  jq --arg c "$CLIKAE_LIB/hooks/cockpit-guard.sh" '(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command) = $c' "$f" > "$f.new" && mv "$f.new" "$f"
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  [[ "$output" == *"cockpit guard installed"* ]] || false
  [ "$(jq -r '.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command' "$f")" = "'$CLIKAE_LIB/hooks/cockpit-guard.sh'" ]
}

@test "marking the SAME tank twice is idempotent and says unchanged" {
  clikae init claude L
  clikae cockpit claude L
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed (unchanged)"* ]] || false
}

@test "a bare unique tank name resolves across engines, like 'clikae <name>'" {
  clikae init claude solo-name
  run clikae cockpit solo-name
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/solo-name" ]
}

@test "an ambiguous bare tank name across engines is refused, not guessed" {
  clikae init claude dup
  clikae init codex dup
  run clikae cockpit dup
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ambiguous tank name: dup"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

# #63 round-6 P3-4: _cockpit_move runs on the RHS of _cockpit_locked's
# `"$@" || rc=$?`, which suppresses errexit for the whole function body —
# so `resolved="$(_cockpit_resolve …)"` used to NOT stop the function on a
# failed resolve (log_fail's `exit 1` only ends the command-substitution
# subshell). Move fell through with $resolved empty and got caught later by
# validate_name instead, printing an extra stray line first: "cli name is
# empty" for an unknown name, or "Invalid cli name: '  clikae cockpit …'"
# (log_dim's suggestion text swallowed as a bogus name) for an ambiguous
# one. State was never at risk either way; this is about the message being
# exactly one line, from the right place.
@test "an unknown tank name is refused with exactly one error, no stray validate_name line (#63 r6 P3-4)" {
  run clikae cockpit nonexistent-tank-zzz
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown tank: nonexistent-tank-zzz"* ]] || false
  [[ "$output" != *"cli name is empty"* ]] || false
  [[ "$output" != *"Invalid cli name"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "an ambiguous bare tank name is refused with exactly its own message, no stray validate_name line (#63 r6 P3-4)" {
  clikae init claude dup2
  clikae init codex dup2
  run clikae cockpit dup2
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ambiguous tank name: dup2"* ]] || false
  [[ "$output" != *"cli name is empty"* ]] || false
  [[ "$output" != *"Invalid cli name"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "moving from A to B removes the guard from A and installs it on B" {
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/A: cockpit guard removed"* ]] || false
  [[ "$output" == *"claude/B: cockpit guard installed"* ]] || false
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/B" ]
}

@test "a human's own PreToolUse hook on A survives the guard's install and later removal, byte for byte" {
  clikae init claude A
  clikae init claude B
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  # Written in jq's own canonical formatting so a later jq-written file can be
  # compared to it directly — every write in this chain goes through jq.
  jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"/human/hook.sh",timeout:10}]}]},env:{X:"1"}}' > "$f"
  cp "$f" "$BATS_TEST_TMPDIR/before-human-hook.json"
  clikae cockpit claude A
  jq -e '.hooks.PreToolUse | any(.matcher == "Bash" and .hooks[0].command == "/human/hook.sh")' "$f" >/dev/null
  clikae cockpit claude B   # moves away from A -> removes OUR block only
  jq -e '.hooks.PreToolUse | any(.matcher == "Bash" and .hooks[0].command == "/human/hook.sh")' "$f" >/dev/null
  run ! _guard_installed "$f"
  cmp "$BATS_TEST_TMPDIR/before-human-hook.json" "$f"
}

@test "a HAND-WRITTEN settings.json survives content-intact but gets reformatted, not byte-for-byte (#63 P2-6)" {
  # The test above's fixture is jq's OWN canonical formatting, chosen so a
  # later jq-written file compares byte-for-byte — that's real, but it's
  # ALSO the one shape where "byte for byte" was never going to be tested.
  # Round-1 review: install/remove round-trips settings.json through jq,
  # which normalizes key order and re-wraps everything, CRLF included — a
  # human-authored file (single-line hooks, no particular key order) is
  # content-intact (jq -S compares equal) but NOT byte-identical. Both
  # things are true and documented (docs/usage.md, clikae cockpit --help,
  # CHANGELOG.md); this fixture is the one that actually proves it.
  clikae init claude A
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  printf '%s\n' \
    '{"env":{"X":"1"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/human/stop.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/human/hook.sh","timeout":10}]}]}}' \
    > "$f"
  cp "$f" "$BATS_TEST_TMPDIR/before-handwritten.json"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  # Content: identical once both sides are canonicalized.
  diff <(jq -S . "$BATS_TEST_TMPDIR/before-handwritten.json") <(jq -S 'del(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard"))' "$f")
  # Formatting: NOT byte-identical -- jq re-wrapped it. If this ever starts
  # passing, either jq changed its own formatting or the write path stopped
  # round-tripping through jq -- either way, docs/usage.md's claim needs a
  # second look before this assertion gets "fixed" by deleting it.
  ! cmp -s "$BATS_TEST_TMPDIR/before-handwritten.json" "$f"
}

@test "--off removes the guard from wherever it is and clears the state" {
  clikae init claude A
  clikae cockpit claude A
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/A: cockpit guard removed"* ]] || false
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
  run clikae cockpit
  [[ "$output" == *"No cockpit set"* ]] || false
}

@test "moving to a new tank sweeps past a broken OLD tank instead of aborting the move (#63 P2-2)" {
  # The move-path twin of "--off sweeps past a broken tank" below. Round 1
  # fixed `--off`'s sweep but left `_cockpit_move` calling
  # `_cockpit_hook_remove` unguarded -- under `bin/clikae`'s `set -eo
  # pipefail`, a broken old-tank settings.json used to abort the WHOLE move:
  # rc=1, one stdout line about the OLD tank, nothing installed on the NEW
  # one, state untouched.
  clikae init claude aaa
  clikae init claude mmm
  clikae cockpit claude aaa
  # Corrupt aaa's settings.json AFTER install (same shape as the --off test
  # below): invalid JSON, so _cockpit_hook_remove fails.
  printf '{"hooks":{"PreToolUse":[{"_clikae":"cockpit-guard" THIS IS NOT VALID JSON\n' \
    > "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
  run clikae cockpit claude mmm
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/aaa"* ]] || false
  [[ "$output" == *"--off"* ]] || false
  # The role still moved: mmm is armed and recorded as the cockpit, despite
  # aaa's guard being stuck (fail-safe, same as --off -- aaa's own guard was
  # never DELETED, just never successfully removed).
  _guard_installed "$CLIKAE_HOME/profiles/claude/mmm/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/mmm" ]
}

@test "moving to a NEW tank that can't be armed leaves the OLD cockpit untouched, rc 1 (#63 P2-1)" {
  # round-3 review: the fix above (P2-2) reordered nothing -- it just made
  # the OLD-tank cleanup non-fatal, so a broken NEW tank still ran through
  # _cockpit_hook_remove on mmm FIRST, unarmed it, and THEN failed to arm
  # aaa: state kept pointing at mmm, but mmm had no guard left, and nothing
  # ever said so again (bare `clikae cockpit` reported a "healthy" mmm).
  # Fail-unsafe. This is red on 84ae5de.
  clikae init claude mmm
  clikae init claude aaa
  clikae cockpit claude mmm
  _guard_installed "$CLIKAE_HOME/profiles/claude/mmm/settings.json"
  printf '{"hooks":{"PreToolUse":[{"_clikae":"cockpit-guard" THIS IS NOT VALID JSON\n' \
    > "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
  run clikae cockpit claude aaa
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not install the guard on claude/aaa"* ]] || false
  # Old cockpit: still armed, state unchanged -- a true no-op.
  _guard_installed "$CLIKAE_HOME/profiles/claude/mmm/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/mmm" ]
}

# _state_probe_env -> path of a BASH_ENV file that wraps `printf` for the ONE
# call shaped like the state record ('%s/%s\n' with two args), so a probe can
# act exactly at the state write while every other write stays real. Modes
# (CKPT_PROBE): shortwrite — a child with RLIMIT_FSIZE=8 and SIGXFSZ ignored
# writes the record, so the kernel really short-writes (the codex review's
# probe); kill — SIGKILL this clikae process at the write, after its
# redirection has opened the target; pause — write, then wait for
# $CKPT_PAUSE_DIR/go (once).
_state_probe_env() {
  local f="$BATS_TEST_TMPDIR/probe-env.sh"
  cat > "$f" <<'PROBE'
printf() {
  if [ "$#" -eq 3 ] && [ "$1" = '%s/%s\n' ]; then
    case "${CKPT_PROBE-}" in
      shortwrite)
        python3 -c '
import os, resource, signal, sys
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
resource.setrlimit(resource.RLIMIT_FSIZE, (8, 8))
data = (sys.argv[1] + "/" + sys.argv[2] + "\n").encode()
n = os.write(1, data)
if n < len(data):
    os.write(1, data[n:])
' "$2" "$3"
        return $? ;;
      kill) kill -KILL $$ ;;
      pause)
        if [ ! -e "$CKPT_PAUSE_DIR/paused" ]; then
          builtin printf "$@"; local rc=$?
          : > "$CKPT_PAUSE_DIR/paused"
          while [ ! -e "$CKPT_PAUSE_DIR/go" ]; do sleep 0.05; done
          return "$rc"
        fi ;;
    esac
  fi
  builtin printf "$@"
}
PROBE
  printf '%s' "$f"
}

# _no_unguarded_cockpit -> fail when the state file names a tank whose
# settings.json carries no guard (the forbidden state these probes hunt).
_no_unguarded_cockpit() {
  local cur
  [ ! -L "$CLIKAE_HOME/state/cockpit" ] || return 0
  cur="$(head -n 1 "$CLIKAE_HOME/state/cockpit" 2>/dev/null || true)"
  [ -n "$cur" ] || return 0
  _guard_installed "$CLIKAE_HOME/profiles/$cur/settings.json" || {
    echo "forbidden: state names $cur and $cur is unguarded" >&2; return 1; }
}

@test "a state file mode 444 no longer blocks a move: the record is replaced atomically, not rewritten in place (#63 r5 P2-3)" {
  # Round 4 treated a 444 state file as a write failure. The record is now a
  # fresh file renamed over the old one, so the directory's permission is
  # what matters — and the move goes through cleanly.
  clikae init claude aaa
  clikae init claude bbb
  clikae cockpit claude aaa
  chmod 444 "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude bbb
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/bbb" ]
  _guard_installed "$CLIKAE_HOME/profiles/claude/bbb/settings.json"
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
}

@test "a state file symlinked elsewhere is refused before any guard is written (#63 r4 P2-1, r5 P2-3)" {
  clikae init claude aaa
  clikae init claude bbb
  clikae cockpit claude aaa
  local target="$CLIKAE_HOME/state/cockpit-real"
  cp "$CLIKAE_HOME/state/cockpit" "$target"
  chmod 444 "$target"
  rm -f "$CLIKAE_HOME/state/cockpit"
  ln -s "$target" "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude bbb
  [ "$status" -ne 0 ]
  [[ "$output" == *"is a symlink or not a regular file"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
  [ "$(cat "$target")" = "claude/aaa" ]
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/bbb/settings.json"
}

@test "probe: a real kernel short write of the record keeps the old state and rolls the new guard back (#63 r5 P2-3)" {
  # codex review probe 1. On f20a603: rc=1, state="claude/B" (8 bytes, no
  # newline), A guarded, B unguarded — the recorded cockpit unguarded, while
  # the error said A was "unchanged".
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=shortwrite run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [[ "$output" == *"claude/A is still the cockpit"* ]] || false
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
  _no_unguarded_cockpit
}

@test "probe: a short write with no prior cockpit leaves nothing recorded and nothing armed (#63 r5 P2-3)" {
  clikae init claude B
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=shortwrite run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cockpit is set"* ]] || false
  [ -z "$(cat "$CLIKAE_HOME/state/cockpit" 2>/dev/null)" ]
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
}

@test "probe: SIGKILL at the state write never empties the record, and doctor names the extra guard (#63 r5 P2-3)" {
  # codex review probe 2. On f20a603 the redirection had already truncated
  # the live file: state empty, A and B both guarded, doctor silent.
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=kill run clikae cockpit claude B
  [ "$status" -eq 137 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  _no_unguarded_cockpit
  run clikae doctor
  [[ "$output" == *"guard also found on tank(s) that are not the recorded cockpit: claude/B"* ]] || false
}

@test "probe: a state path symlinked at the new tank's settings.json is refused; that settings.json is untouched (#63 r5 P2-3)" {
  # codex review probe 3. On f20a603 the move installed B's guard, then
  # `printf > state` followed the symlink and replaced B's JSON with the text
  # "claude/B": rc=0, state named B, B unguarded and invalid.
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  printf '{}\n' > "$CLIKAE_HOME/profiles/claude/B/settings.json"
  rm -f "$CLIKAE_HOME/state/cockpit"
  ln -s "$CLIKAE_HOME/profiles/claude/B/settings.json" "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [ "$(cat "$CLIKAE_HOME/profiles/claude/B/settings.json")" = "{}" ]
  [ -L "$CLIKAE_HOME/state/cockpit" ]
  run clikae doctor
  [[ "$output" == *"is a symlink or not a regular file"* ]] || false
}

_wait_for_file() {
  for _ in $(seq 1 400); do [ -e "$1" ] && return 0; sleep 0.05; done
  return 1
}

@test "two concurrent moves: exactly one transition wins, the other refuses, the recorded cockpit stays guarded (#63 r5 P2-4)" {
  # codex review schedule, with the real functions: P1 (A→B) installs B,
  # writes the record, pauses; P2 (B→A) runs start to finish; P1 resumes.
  # On f20a603 both returned 0 and neither A nor B was guarded.
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  local pd="$BATS_TEST_TMPDIR/pause"; mkdir -p "$pd"
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=pause CKPT_PAUSE_DIR="$pd" \
    "$CLIKAE_BIN" cockpit claude B > "$BATS_TEST_TMPDIR/p1.out" 2>&1 &
  local p1=$!
  _wait_for_file "$pd/paused" || { : > "$pd/go"; wait "$p1" || true; echo "P1 never reached the state write" >&2; false; }
  local p2_status=0
  CLIKAE_SETTINGS_LOCK_WAIT_S=1 "$CLIKAE_BIN" cockpit claude A > "$BATS_TEST_TMPDIR/p2.out" 2>&1 || p2_status=$?
  : > "$pd/go"
  local p1_status=0
  wait "$p1" || p1_status=$?
  cat "$BATS_TEST_TMPDIR/p1.out" "$BATS_TEST_TMPDIR/p2.out" >&2
  [ "$p1_status" -eq 0 ]
  [ "$p2_status" -ne 0 ]
  grep -q "in progress" "$BATS_TEST_TMPDIR/p2.out"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/B" ]
  _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  _no_unguarded_cockpit
  [ ! -e "$CLIKAE_HOME/state/settings.lock" ]
}

@test "a waiting move proceeds once the running one finishes (#63 r5 P2-4)" {
  clikae init claude A
  clikae init claude B
  clikae init claude C
  clikae cockpit claude A
  local pd="$BATS_TEST_TMPDIR/pause"; mkdir -p "$pd"
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=pause CKPT_PAUSE_DIR="$pd" \
    "$CLIKAE_BIN" cockpit claude B > "$BATS_TEST_TMPDIR/p1.out" 2>&1 &
  local p1=$!
  _wait_for_file "$pd/paused" || { : > "$pd/go"; wait "$p1" || true; false; }
  CLIKAE_SETTINGS_LOCK_WAIT_S=30 "$CLIKAE_BIN" cockpit claude C > "$BATS_TEST_TMPDIR/p2.out" 2>&1 &
  local p2=$!
  sleep 0.5
  : > "$pd/go"
  wait "$p1"
  wait "$p2"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/C" ]
  _guard_installed "$CLIKAE_HOME/profiles/claude/C/settings.json"
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
}

@test "--off and settings apply take the same lock: both refuse while a transition holds it (#63 r5 P2-4)" {
  clikae init claude A
  clikae cockpit claude A
  mkdir -p "$CLIKAE_HOME/state/settings.lock"
  printf '%s\n' "$$" > "$CLIKAE_HOME/state/settings.lock/pid"   # this live test process
  CLIKAE_SETTINGS_LOCK_WAIT_S=1 run clikae cockpit --off
  [ "$status" -ne 0 ]
  [[ "$output" == *"in progress"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  CLIKAE_SETTINGS_LOCK_WAIT_S=1 run clikae settings apply claude A
  [ "$status" -ne 0 ]
  [[ "$output" == *"in progress"* ]] || false
  rm -rf "$CLIKAE_HOME/state/settings.lock"
}

@test "a lock left by a dead holder is named, not broken; doctor reports it (#63 r5 P2-4)" {
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  local dead; dead="$(sh -c 'echo $$')"
  mkdir -p "$CLIKAE_HOME/state/settings.lock"
  printf '%s\n' "$dead" > "$CLIKAE_HOME/state/settings.lock/pid"
  run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [[ "$output" == *"pid $dead is not running"* ]] || false
  [[ "$output" == *"rm -rf"* ]] || false
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
  run clikae doctor
  [[ "$output" == *"stale settings lock"* ]] || false
}

# #63 round-6 P3-3: --off is defined (P1-3) as the operator's last-resort
# escape hatch — it must never stay blocked. Before this fix it took the
# exact same lock as a role move (test above) and refused identically to a
# crashed transition's stale lock, exactly like a LIVE holder does — the
# one command meant to recover from a crash did nothing when a crash was
# the reason it was needed. A move onto a NAMED tank still refuses on a
# stale lock unchanged (see the test above, which this must NOT break);
# only --off auto-breaks a lock whose pid is confirmably dead.
@test "--off breaks a stale (dead-pid) lock instead of staying blocked by it (#63 r6 P3-3)" {
  clikae init claude A
  clikae cockpit claude A
  local dead; dead="$(sh -c 'echo $$')"
  mkdir -p "$CLIKAE_HOME/state/settings.lock"
  printf '%s\n' "$dead" > "$CLIKAE_HOME/state/settings.lock/pid"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *"breaking a stale settings lock"* ]] || false
  [[ "$output" == *"cockpit: off"* ]] || false
  [ ! -d "$CLIKAE_HOME/state/settings.lock" ]
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
}

@test "--off still refuses while a LIVE holder has the lock (unaffected by the stale-lock break, #63 r6 P3-3)" {
  clikae init claude A
  clikae cockpit claude A
  mkdir -p "$CLIKAE_HOME/state/settings.lock"
  printf '%s\n' "$$" > "$CLIKAE_HOME/state/settings.lock/pid"   # this live test process
  CLIKAE_SETTINGS_LOCK_WAIT_S=1 run clikae cockpit --off
  [ "$status" -ne 0 ]
  [[ "$output" == *"in progress"* ]] || false
  [[ "$output" != *"breaking a stale settings lock"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  rm -rf "$CLIKAE_HOME/state/settings.lock"
}

# #63 round-6 P3-3: a SIGKILL between _cockpit_state_write's mktemp and mv
# leaves a `.cockpit.XXXXXX` scratch file in state/ forever — harmless, but
# nothing ever swept it. The next successful state write now does.
@test "a stray .cockpit.XXXXXX temp file from an earlier crash is swept on the next successful state write (#63 r6 P3-3)" {
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  : > "$CLIKAE_HOME/state/.cockpit.deadbeef"   # left behind by a hypothetical earlier crash
  run clikae cockpit claude B
  [ "$status" -eq 0 ]
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/B" ]
  local strays; strays="$(find "$CLIKAE_HOME/state" -maxdepth 1 -name '.cockpit.*' 2>/dev/null)"
  [ -z "$strays" ]
}

@test "moving to a symlink alias of the current cockpit is refused as the same tank; the guard stays (#63 r5 P2-2)" {
  # codex review repro: with A armed, replace B's directory with a symlink
  # to A. On f20a603 the move returned 0, state became claude/B, and the
  # shared settings.json had no guard.
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  rm -rf "$CLIKAE_HOME/profiles/claude/B"
  ln -s "$CLIKAE_HOME/profiles/claude/A" "$CLIKAE_HOME/profiles/claude/B"
  run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [[ "$output" == *"same physical tank"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
}

@test "moving to a tank whose settings.json is a hard link of the cockpit's is refused the same way (#63 r5 P2-2)" {
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  rm -f "$CLIKAE_HOME/profiles/claude/B/settings.json"
  ln "$CLIKAE_HOME/profiles/claude/A/settings.json" "$CLIKAE_HOME/profiles/claude/B/settings.json"
  run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [[ "$output" == *"same physical tank"* ]] || false
  _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "claude/A" ]
}

# _cp_swap_shim -> a `cp` on PATH that, the first time it is handed a matching
# path, replaces the tank's live settings.json with a symlink to a sentinel
# file and then runs the real cp. SHIM_WHEN=live matches the live
# settings.json (on f20a603 that is the seed copy, right after the JSON
# read — the codex review's probe); SHIM_WHEN=snapshot matches the private
# snapshot (after the read, before the backup).
_cp_swap_shim() {
  local bin="$BATS_TEST_TMPDIR/shim" real
  real="$(command -v cp)"
  mkdir -p "$bin"
  cat > "$bin/cp" <<SHIM
#!/usr/bin/env bash
# \$2 is the SOURCE in every clikae call shape (cp -p SRC DST, cp -RPp SRC DST).
if [ ! -e "\$SHIM_DONE" ]; then
  case "\$SHIM_WHEN:\${2-}" in
    live:*/profiles/claude/L/settings.json|snapshot:*/.clikae-snap.*/settings.json)
      : > "\$SHIM_DONE"
      rm -f "\$SHIM_TARGET"; ln -s "\$SHIM_SENTINEL" "\$SHIM_TARGET" ;;
  esac
fi
exec "$real" "\$@"
SHIM
  chmod +x "$bin/cp"
  printf '%s' "$bin"
}

@test "probe: settings.json swapped for a symlink right after it is read never lands the link's target in a backup (#63 r5 P3-3)" {
  clikae init claude L
  local d="$CLIKAE_HOME/profiles/claude/L" sentinel="$BATS_TEST_TMPDIR/sentinel"
  printf 'SYNTHETIC_SENTINEL\n' > "$sentinel"
  printf '{"env":{"X":"1"}}\n' > "$d/settings.json"
  local shim; shim="$(_cp_swap_shim)"
  run env PATH="$shim:$PATH" SHIM_WHEN=live SHIM_DONE="$BATS_TEST_TMPDIR/done" \
    SHIM_TARGET="$d/settings.json" SHIM_SENTINEL="$sentinel" "$CLIKAE_BIN" cockpit claude L
  [ -e "$BATS_TEST_TMPDIR/done" ]                      # the swap really happened
  local move_status="$status" move_output="$output"
  # `run !`, never a bare `! cmd`: bats does not fail a test on a negated
  # command in the middle of it.
  run ! grep -rl SYNTHETIC_SENTINEL "$d"/settings.json.clikae.bak.* 2>/dev/null
  [ "$move_status" -ne 0 ]
  [[ "$move_output" == *"turned into a link or non-file while it was being read"* ]] || false
  [ "$(cat "$sentinel")" = "SYNTHETIC_SENTINEL" ]
  [ -z "$(find "$d" -name '.clikae-snap.*')" ]         # snapshot directory cleaned up
}

@test "probe: a swap AFTER the snapshot changes nothing that is read — backup and content come from the snapshot (#63 r5 P3-3)" {
  clikae init claude L
  local d="$CLIKAE_HOME/profiles/claude/L" sentinel="$BATS_TEST_TMPDIR/sentinel"
  printf 'SYNTHETIC_SENTINEL\n' > "$sentinel"
  printf '{"env":{"X":"1"}}\n' > "$d/settings.json"
  cp "$d/settings.json" "$BATS_TEST_TMPDIR/original.json"
  local shim; shim="$(_cp_swap_shim)"
  run env PATH="$shim:$PATH" SHIM_WHEN=snapshot SHIM_DONE="$BATS_TEST_TMPDIR/done" \
    SHIM_TARGET="$d/settings.json" SHIM_SENTINEL="$sentinel" "$CLIKAE_BIN" cockpit claude L
  [ -e "$BATS_TEST_TMPDIR/done" ]
  [ "$status" -eq 0 ]
  run ! grep -rl SYNTHETIC_SENTINEL "$d"/settings.json.clikae.bak.* 2>/dev/null
  cmp "$BATS_TEST_TMPDIR/original.json" "$d"/settings.json.clikae.bak.*
  [ ! -L "$d/settings.json" ]
  _guard_installed "$d/settings.json"
  [ "$(jq -r .env.X "$d/settings.json")" = 1 ]
  [ "$(cat "$sentinel")" = "SYNTHETIC_SENTINEL" ]
}

@test "a tank directory that is a symlink to a real directory is written through its physical path (#63 r5 P3-3)" {
  clikae init claude L
  mv "$CLIKAE_HOME/profiles/claude/L" "$BATS_TEST_TMPDIR/realL"
  ln -s "$BATS_TEST_TMPDIR/realL" "$CLIKAE_HOME/profiles/claude/L"
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  _guard_installed "$BATS_TEST_TMPDIR/realL/settings.json"
  [ -L "$CLIKAE_HOME/profiles/claude/L" ]
}

@test "--off with nothing set is an idempotent no-op" {
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *"already off"* ]] || false
}

@test "--off is idempotent when run twice in a row" {
  clikae init claude A
  clikae cockpit claude A
  clikae cockpit --off
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [[ "$output" == *"already off"* ]] || false
}

@test "--off sweeps a stray guard even when the state file disagrees (crash-recovery)" {
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  # Simulate a crash mid-move: state now claims B, but A still carries the guard.
  printf 'claude/B\n' > "$CLIKAE_HOME/state/cockpit"
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "--off sweeps past a broken tank instead of aborting the whole sweep (#63 P1-3)" {
  # The exact shape from the round-1 review: `list_all_profiles | sort` puts
  # an alphabetically-earlier broken tank in front of the real cockpit, and
  # `bin/clikae`'s `set -eo pipefail` used to let ITS failure abort the loop
  # before it ever reached zzz -- the guard stayed live and --off, the one
  # way out, printed a message about aaa and did nothing else.
  clikae init claude aaa
  clikae init claude mmm
  clikae init claude zzz
  clikae cockpit claude zzz
  # Corrupt aaa's settings.json AFTER install, but leave the marker text
  # inside it -- so --off's own text-grep pre-filter still picks it up as
  # "has our guard, needs removing" and hands it to jq, which then fails.
  printf '{"hooks":{"PreToolUse":[{"_clikae":"cockpit-guard" THIS IS NOT VALID JSON\n' \
    > "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
  run clikae cockpit --off
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude/aaa"* ]] || false
  # zzz -- alphabetically AFTER the broken tank -- must still be cleaned up.
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/zzz/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
  # mmm was never touched -- no marker, not part of the failure list either.
  [[ "$output" != *"claude/mmm"* ]] || false
}

# --- #61 round-6 P2-2: --off is the escape hatch of LAST RESORT ---------------
# It may not inherit an enumerator whose whole job is to EXCLUDE directories.
# The moment a guarded tank lost its `.clikae-tank` marker it dropped out of
# `list_all_profiles`, `--off` swept past it without seeing it, printed
# `cockpit: off`, returned 0, and cleared `state/cockpit` — leaving the hook
# installed and nothing on disk pointing at it. The hook does not read
# `state/cockpit`, so it kept refusing every Agent spawn in that tank forever,
# and `doctor` reported the directory as an ordinary stray without ever
# mentioning the guard.
@test "#61 round-6 P2-2: --off removes the guard from a cockpit tank whose marker is GONE" {
  clikae init claude pilot
  clikae init claude other
  clikae cockpit claude pilot
  _guard_installed "$CLIKAE_HOME/profiles/claude/pilot/settings.json"
  rm -f "$CLIKAE_HOME/profiles/claude/pilot/.clikae-tank"
  run clikae cockpit --off
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/pilot/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
  # the ruler: no live settings.json anywhere in the store still carries it
  run bash -c 'grep -l cockpit-guard "$1"/profiles/*/*/settings.json 2>/dev/null' _ "$CLIKAE_HOME"
  [ -z "$output" ] || { echo "left behind: $output"; false; }
}

@test "#61 round-6 P2-2: --off removes the guard when the marker is UNREADABLE (mode 000)" {
  if [ "$(id -u)" = "0" ]; then skip "root reads a mode-000 file"; fi
  clikae init claude pilot
  clikae cockpit claude pilot
  chmod 000 "$CLIKAE_HOME/profiles/claude/pilot/.clikae-tank"
  run clikae cockpit --off
  local st="$status" out="$output"
  chmod 644 "$CLIKAE_HOME/profiles/claude/pilot/.clikae-tank" 2>/dev/null || true
  [ "$st" -eq 0 ] || { echo "$out"; false; }
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/pilot/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "#61 round-6 P2-2: --off SAYS the recorded cockpit directory is gone, and still clears the record" {
  clikae init claude pilot
  clikae cockpit claude pilot
  rm -rf "$CLIKAE_HOME/profiles/claude/pilot"
  run clikae cockpit --off
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"claude/pilot"* ]] || { echo "silent about the missing tank: $output"; false; }
  [[ "$output" == *"no longer exists"* ]] || { echo "$output"; false; }
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "#61 round-6 P2-2: a marker-less guarded tank the state does NOT name is still swept" {
  # The crash-recovery case from the test above, plus the marker loss: the
  # state names B, the guard is on A, and A is no longer enumerable.
  clikae init claude A
  clikae init claude B
  clikae cockpit claude A
  printf 'claude/B\n' > "$CLIKAE_HOME/state/cockpit"
  rm -f "$CLIKAE_HOME/profiles/claude/A/.clikae-tank"
  run clikae cockpit --off
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/A/settings.json"
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "#61 round-6 P2-2: --off reports the guard removed exactly once for a symlink-aliased cockpit" {
  clikae init claude real
  clikae cockpit claude real
  ln -s "$CLIKAE_HOME/profiles/claude/real" "$CLIKAE_HOME/profiles/claude/alias"
  run clikae cockpit --off
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c 'cockpit guard removed')" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" != *"not installed here"* ]] || { echo "$output"; false; }
  run ! _guard_installed "$CLIKAE_HOME/profiles/claude/real/settings.json"
}

@test "#114: --off on codex and antigravity too — a move interrupted mid-way, both markers lost, a live allowance" {
  # The round-6 P2-2 tests above are claude-only and one state at a time. The
  # sweep reads settings.json, never the engine or the marker, so every engine
  # must come out the same: a move that crashed after arming the NEW tank and
  # before disarming the OLD one (both guarded, state still names the old),
  # the new tank's marker gone, the old one's unreadable, and --allow-agents live.
  if [ "$(id -u)" = "0" ]; then skip "root reads a mode-000 file"; fi
  local e d
  for e in claude codex antigravity; do
    mkdir -p "$CLIKAE_HOME/profiles/$e/old" "$CLIKAE_HOME/profiles/$e/new"
    printf '%s\n' "$e" > "$CLIKAE_HOME/profiles/$e/old/.clikae-tank"
    printf '%s\n' "$e" > "$CLIKAE_HOME/profiles/$e/new/.clikae-tank"
    clikae cockpit "$e" old
    d="$CLIKAE_HOME/profiles/$e"
    cp "$d/old/settings.json" "$d/new/settings.json"
    rm -f "$d/new/.clikae-tank"
    chmod 000 "$d/old/.clikae-tank"
    clikae cockpit --allow-agents 1h
    run clikae cockpit --off
    local st="$status" out="$output"
    chmod 644 "$d/old/.clikae-tank"
    [ "$st" -eq 0 ] || { echo "$e: $out"; false; }
    [ "$(printf '%s\n' "$out" | grep -c 'cockpit guard removed')" -eq 2 ] || { echo "$e: $out"; false; }
    [[ "$out" != *"Permission denied"* ]] || { echo "$e: raw error: $out"; false; }
    run bash -c 'grep -l cockpit-guard "$1"/profiles/*/*/settings.json 2>/dev/null' _ "$CLIKAE_HOME"
    [ -z "$output" ] || { echo "$e: left behind: $output"; false; }
    [ ! -f "$CLIKAE_HOME/state/cockpit" ] || { echo "$e: state kept"; false; }
    [ ! -f "$CLIKAE_HOME/state/cockpit-allow" ] || { echo "$e: allowance kept"; false; }
  done
}

@test "--off clears a live timed allowance too, not just the guard and state (#63 P1-3)" {
  clikae init claude A
  clikae cockpit claude A
  clikae cockpit --allow-agents 1h
  [ -f "$CLIKAE_HOME/state/cockpit-allow" ]
  run clikae cockpit --off
  [ "$status" -eq 0 ]
  [ ! -f "$CLIKAE_HOME/state/cockpit-allow" ]
}

@test "settings apply --check on a cockpit tank reports the guard as expected, not as drift" {
  clikae init claude L
  clikae cockpit claude L
  run clikae settings apply claude L --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/L: unchanged"* ]] || false
}

@test "cockpit requires jq and does not write without it" {
  local nojq="$BATS_TEST_TMPDIR/nojq"
  path_without_jq "$nojq"
  PATH="$nojq" command -v jq >/dev/null 2>&1 && skip "jq is on PATH even without /usr/bin and /bin"
  clikae init claude L
  run env PATH="$nojq" "$CLIKAE_BIN" cockpit claude L
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires jq"* ]] || false
  [ ! -f "$CLIKAE_HOME/state/cockpit" ]
}

@test "cockpit refuses a tank that does not exist" {
  run clikae cockpit claude nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]] || false
}

@test "--allow-agents writes a timed allowance and reports when it expires" {
  clikae init claude L
  clikae cockpit claude L
  run clikae cockpit --allow-agents 4h
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed until"* ]] || false
  [ -f "$CLIKAE_HOME/state/cockpit-allow" ]
  local exp now
  exp="$(cat "$CLIKAE_HOME/state/cockpit-allow")"
  now="$(date +%s)"
  [ "$exp" -gt "$now" ]
  [ "$exp" -le "$((now + 14401))" ]
}

@test "--allow-agents rejects a bad duration and writes nothing" {
  run clikae cockpit --allow-agents nonsense
  [ "$status" -ne 0 ]
  [ ! -f "$CLIKAE_HOME/state/cockpit-allow" ]
}

@test "bare 'clikae cockpit' warns when the recorded tank no longer exists (#63 P3-8)" {
  clikae init claude A
  clikae cockpit claude A
  # Simulate the tank having been deleted out from under the role -- the
  # state file (and the marker on whatever settings.json got deleted with
  # it) is now the only trace the role ever existed.
  rm -rf "$CLIKAE_HOME/profiles/claude/A"
  run clikae cockpit
  [ "$status" -eq 0 ]
  [[ "$output" == *"cockpit: claude/A"* ]] || false
  [[ "$output" == *"no longer exists"* ]] || false
  [[ "$output" == *"--off"* ]] || false
}

# --- #109 P3-8: `agy` is accepted where `antigravity` is ---------------------
# `clikae burn agy work` has always worked, and `_cockpit_is_recorded` has
# always treated agy and antigravity as one engine — but `clikae cockpit agy
# work` died on `Tank does not exist: agy/work`, because the two-arg resolve
# handed `agy` straight to profile_exists, which only knows the ON-DISK name.
# Installing the Claude hook on an agy tank has no real meaning; a CLI surface
# that accepts a name in one command and rejects it in the next does.

_cockpit_make_agy_tank() {   # <tank> — a tank dir with the marker `clikae init` writes
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/$1"
  printf 'antigravity\n' > "$CLIKAE_HOME/profiles/antigravity/$1/.clikae-tank"
}

@test "#109 P3-8: 'clikae cockpit agy <tank>' marks the tank, recorded under its on-disk name" {
  _cockpit_make_agy_tank work
  run clikae cockpit agy work
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [[ "$output" != *"Tank does not exist"* ]] || { echo "$output" >&2; false; }
  [[ "$output" == *"cockpit guard installed"* ]] || { echo "$output" >&2; false; }
  # state records the store's spelling, not the alias — `antigravity` is what
  # profile_dir/list_all_profiles speak, and the guard's reserve listing reads
  # state with those same names.
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "antigravity/work" ]
  _guard_installed "$CLIKAE_HOME/profiles/antigravity/work/settings.json"
}

@test "#109 P3-8: 'agy' and 'antigravity' name the same cockpit — the second is an idempotent no-op" {
  _cockpit_make_agy_tank work
  clikae cockpit antigravity work
  run clikae cockpit agy work
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ "$(cat "$CLIKAE_HOME/state/cockpit")" = "antigravity/work" ]
  _guard_installed "$CLIKAE_HOME/profiles/antigravity/work/settings.json"
  # the role did not move to a second tank on the way: still exactly one
  [ "$(grep -c . "$CLIKAE_HOME/state/cockpit")" -eq 1 ]
}

@test "#109 P3-8: an unknown agy tank still fails, naming the on-disk engine" {
  run clikae cockpit agy nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tank does not exist: antigravity/nosuch"* ]] || { echo "$output" >&2; false; }
}

@test "installing from a git checkout warns that the guard's path is not stable (#63 P3-12)" {
  # This test environment (CLIKAE_LIB pointing at the checkout/worktree this
  # suite runs from) IS the shape the warning exists for -- a real install
  # (install.sh, Homebrew) never ships a .git alongside lib/, so the warning
  # is silent there. See tests/fixtures/cockpit-guard/ for the same
  # distinction on the payload side.
  [ -e "$CLIKAE_LIB/../.git" ]   # sanity: this test's own premise holds
  clikae init claude L
  run clikae cockpit claude L
  [ "$status" -eq 0 ]
  [[ "$output" == *"cockpit guard installed"* ]] || false
  [[ "$output" == *"guard goes silent if that checkout is ever removed"* ]] || false
}

# --- #103 round-3 nits --------------------------------------------------------

@test "#103: installing the guard keeps settings.json's prior file mode" {
  clikae init claude A
  local f="$CLIKAE_HOME/profiles/claude/A/settings.json"
  printf '{"env":{"X":"1"}}\n' > "$f"
  chmod 600 "$f"
  run clikae cockpit claude A
  [ "$status" -eq 0 ]
  _guard_installed "$f"
  local mode
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
  [ "$mode" = "600" ] || { echo "mode after install: $mode" >&2; false; }
}

@test "#103: a skipped install reports on stderr only, in the same 'skipped —' form" {
  clikae init claude A
  printf '{not json\n' > "$CLIKAE_HOME/profiles/claude/A/settings.json"
  # `clikae` is a helpers function, so split the streams here rather than
  # in a `bash -c` (which would find some other clikae on PATH).
  clikae cockpit claude A >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" || true
  [ ! -s "$BATS_TEST_TMPDIR/out" ] || { cat "$BATS_TEST_TMPDIR/out" >&2; false; }
  output="$(cat "$BATS_TEST_TMPDIR/err")"
  [[ "$output" == *"claude/A: skipped — settings.json is not valid JSON"* ]] || { echo "$output" >&2; false; }
}
