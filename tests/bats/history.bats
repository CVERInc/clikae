#!/usr/bin/env bats
# tests/bats/history.bats — the "what clikae did" log (lib/core/history.sh) and its
# surfacing in `clikae status`. Carries (clikae to / board relay, later the
# supervisor) append here so you can see what moved where, even while away.

load '../helpers'

@test "history_log appends and history_recent reads it back" {
  source "$CLIKAE_TEST_ROOT/lib/core/history.sh"
  history_log "carry claude/a -> claude/b"
  run history_recent 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"carry claude/a -> claude/b"* ]] || false
}

@test "history_recent returns nothing when there is no log yet" {
  source "$CLIKAE_TEST_ROOT/lib/core/history.sh"
  run history_recent 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clikae status shows a recent-carries section when history exists" {
  source "$CLIKAE_TEST_ROOT/lib/core/history.sh"
  clikae init claude a
  history_log "to: relay claude a b"
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"recent carries"* ]] || false
  [[ "$output" == *"relay claude a b"* ]] || false
}

@test "clikae status has no recent-carries section with empty history" {
  clikae init claude a
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" != *"recent carries"* ]] || false
}

@test "clikae status --json is unaffected by history" {
  source "$CLIKAE_TEST_ROOT/lib/core/history.sh"
  clikae init claude a
  history_log "to: relay claude a b"
  run clikae status --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"recent carries"* ]] || false   # json stays machine-clean
  [[ "$output" == "["* ]] || false
}
