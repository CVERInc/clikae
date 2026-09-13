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
