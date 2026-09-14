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
  # the marker command points at the real guard script
  jq -e --arg want "$CLIKAE_LIB/hooks/cockpit-guard.sh" \
    '(.hooks.PreToolUse[] | select(._clikae == "cockpit-guard") | .hooks[0].command) == $want' \
    "$CLIKAE_HOME/profiles/claude/L/settings.json" >/dev/null
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
  ! _guard_installed "$CLIKAE_HOME/profiles/claude/aaa/settings.json"
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
  ! _guard_installed "$CLIKAE_HOME/profiles/claude/bbb/settings.json"
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
  ! _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
  [[ "$output" == *"claude/A is still the cockpit"* ]] || false
  _no_unguarded_cockpit
}

@test "probe: a short write with no prior cockpit leaves nothing recorded and nothing armed (#63 r5 P2-3)" {
  clikae init claude B
  BASH_ENV="$(_state_probe_env)" CKPT_PROBE=shortwrite run clikae cockpit claude B
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cockpit is set"* ]] || false
  [ -z "$(cat "$CLIKAE_HOME/state/cockpit" 2>/dev/null)" ]
  ! _guard_installed "$CLIKAE_HOME/profiles/claude/B/settings.json"
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
