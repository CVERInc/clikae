#!/usr/bin/env bats
# tests/bats/solo.bats — `clikae solo`: mark a tank standalone (out of the fleet).
# The marker drives the burn/relay rotation skip and the `memory share` refusal;
# here we cover the command itself (mark / --off / list / errors). (`[[ … ]]`
# assertions carry `|| false` — see tests/README.md.)

load '../helpers'

@test "solo: marks a tank, with a reason" {
  clikae init claude work
  run clikae solo claude work "client-only, keep separate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now solo"* ]] || false
  [ -f "$CLIKAE_HOME/profiles/claude/work/clikae-meta/solo" ]
  run cat "$CLIKAE_HOME/profiles/claude/work/clikae-meta/solo"
  [[ "$output" == *"client-only"* ]] || false
}

@test "solo --off: returns a tank to the fleet" {
  clikae init claude work
  clikae solo claude work
  run clikae solo claude work --off
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejoined the fleet"* ]] || false
  [ ! -f "$CLIKAE_HOME/profiles/claude/work/clikae-meta/solo" ]
}

@test "solo (no args): lists the solo tanks" {
  clikae init claude work
  clikae init claude play
  clikae solo claude play "standalone"
  run clikae solo
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/play"* ]] || false
  [[ "$output" == *"standalone"* ]] || false
  [[ "$output" != *"claude/work"* ]] || false          # not solo → not listed
}

@test "solo (no args): says so when nothing is solo" {
  clikae init claude work
  run clikae solo
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]] || false
}

@test "solo: rejects an unknown tank" {
  run clikae solo claude nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tank"* ]] || false
}

@test "solo: works for an agy tank (agy → antigravity)" {
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/bot"
  run clikae solo agy bot
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/antigravity/bot/clikae-meta/solo" ]   # resolved to antigravity
}

@test "solo: tank_is_solo predicate matches the marker" {
  clikae init codex work
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  run tank_is_solo codex work
  [ "$status" -ne 0 ]                                   # not solo yet
  clikae solo codex work
  run tank_is_solo codex work
  [ "$status" -eq 0 ]                                   # now solo
}
