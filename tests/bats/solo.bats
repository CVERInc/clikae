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

@test "board's solo toggle leaves/rejoins the group like the CLI (no 'solo but still sharing')" {
  # The board's `s` key delegates to `clikae solo`, so toggling solo on a SHARED
  # tank must also leave the Soul group — not just flip the marker, which produced
  # the impossible "solo BUT STILL SHARING" state. Then toggling back rejoins it.
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/soul.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
  clikae init claude work
  clikae memory share brain claude work
  [ -n "$(soul_group_for_tank claude work)" ]        # shared to start
  _home_toggle_solo claude work                      # → solo
  [ -f "$CLIKAE_HOME/profiles/claude/work/clikae-meta/solo" ]
  [ -z "$(soul_group_for_tank claude work)" ]        # left the group, not left dangling
  _home_toggle_solo claude work                      # → un-solo
  [ ! -f "$CLIKAE_HOME/profiles/claude/work/clikae-meta/solo" ]
  [ -n "$(soul_group_for_tank claude work)" ]        # rejoined the machine default group
}

@test "solo --off rejoins the group it left, even with no machine default set" {
  # 🔴 The round trip that cost a real tank its brain (2026-08-19). `solo` leaves
  # the shared group; `--off` used to decide where to rejoin by reading the
  # MACHINE DEFAULT, which is written only by the first `memory share` ever run
  # and is empty on plenty of installs. With it empty, `--off` rejoined nothing:
  # the marker came off, the board said "in the fleet", and the memory slot
  # stayed the empty directory the isolate left behind. `soul-default` is
  # deliberately blanked here to reproduce exactly that machine.
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/soul.sh"
  clikae init claude work
  clikae memory share brain claude work
  : > "$CLIKAE_HOME/soul-default"        # the machine default is EMPTY
  [ "$(soul_group_for_tank claude work)" = "brain" ]

  clikae solo claude work
  [ -z "$(soul_group_for_tank claude work)" ]                 # left the group
  [ "$(cat "$CLIKAE_HOME/profiles/claude/work/clikae-meta/soul-left")" = "brain" ]

  run clikae solo claude work --off
  [ "$status" -eq 0 ]
  [ "$(soul_group_for_tank claude work)" = "brain" ]          # …and got back in
  # The breadcrumb is consumed, so a later solo/--off can't rejoin a stale group.
  [ ! -f "$CLIKAE_HOME/profiles/claude/work/clikae-meta/soul-left" ]
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
