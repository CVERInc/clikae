#!/usr/bin/env bats
# tests/bats/pool.bats — `clikae pool` + the pool_next fall-through logic.

load '../helpers'

@test "pool add / list / remove round-trips, preserving priority order" {
  run clikae pool list
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty"* ]]

  clikae pool add claude/a
  clikae pool add claude/b
  clikae pool add codex/work
  run clikae pool list
  [ "$status" -eq 0 ]
  # Order preserved (a before b before codex).
  [[ "$output" == *"1. claude/a"* ]]
  [[ "$output" == *"2. claude/b"* ]]
  [[ "$output" == *"3. codex/work"* ]]

  clikae pool remove claude/b
  run clikae pool list
  [[ "$output" == *"claude/a"* ]]
  [[ "$output" != *"claude/b"* ]]
  [[ "$output" == *"codex/work"* ]]
}

@test "pool add is idempotent and rejects unknown targets" {
  clikae pool add claude/a
  run clikae pool add claude/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already in the pool"* ]]

  run clikae pool add nosuchcli/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown handoff target"* ]]
}

@test "pool_next advances down the priority list" {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/pool.sh"
  clikae pool add claude/a
  clikae pool add claude/b
  clikae pool add antigravity

  [ "$(pool_next claude/a)" = "claude/b" ]
  [ "$(pool_next claude/b)" = "antigravity" ]
  # Last entry → nowhere left to fall.
  [ -z "$(pool_next antigravity)" ]
  # Unknown current → start at the top.
  [ "$(pool_next codex/none)" = "claude/a" ]
}
