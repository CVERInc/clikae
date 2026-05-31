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

@test "pool --json emits [] for an empty pool" {
  run clikae pool --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]

  # `pool list --json` is the same path.
  run clikae pool list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "pool --json emits position/target/cli/profile in priority order" {
  clikae pool add claude/a
  clikae pool add codex/work
  clikae pool add antigravity

  run clikae pool --json
  [ "$status" -eq 0 ]
  # Valid JSON.
  echo "$output" | python3 -m json.tool >/dev/null

  # Positions in priority order.
  [[ "$output" == *'"position":1,"target":"claude/a","cli":"claude","profile":"a"'* ]]
  [[ "$output" == *'"position":2,"target":"codex/work","cli":"codex","profile":"work"'* ]]
  # Launch-only target → profile null.
  [[ "$output" == *'"position":3,"target":"antigravity","cli":"antigravity","profile":null'* ]]

  # The human list is unchanged alongside --json.
  run clikae pool list
  [[ "$output" == *"1. claude/a"* ]]
  [[ "$output" == *"3. antigravity"* ]]
}

@test "pool list --json rejects unexpected arguments" {
  run clikae pool list --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]]
}

@test "pool seed fills an empty pool from existing profiles, in name order" {
  clikae init claude a
  clikae init claude b
  clikae init codex work

  run clikae pool seed
  [ "$status" -eq 0 ]

  run clikae pool list
  [ "$status" -eq 0 ]
  # All switchable profiles added, sorted (claude/a, claude/b, codex/work).
  [[ "$output" == *"1. claude/a"* ]]
  [[ "$output" == *"2. claude/b"* ]]
  [[ "$output" == *"3. codex/work"* ]]
}

@test "pool seed <cli> only adds that cli's profiles" {
  clikae init claude a
  clikae init codex work

  run clikae pool seed claude
  [ "$status" -eq 0 ]

  run clikae pool list
  [[ "$output" == *"claude/a"* ]]
  [[ "$output" != *"codex/work"* ]]
}

@test "pool seed is idempotent and skips what's already pooled" {
  clikae init claude a
  clikae pool add claude/a

  run clikae pool seed
  [ "$status" -eq 0 ]
  [[ "$output" == *"already covers"* ]]

  # claude/a appears exactly once.
  run clikae pool list
  local n; n="$(printf '%s\n' "$output" | grep -c 'claude/a')"
  [ "$n" -eq 1 ]
}

@test "pool seed with no profiles says so" {
  run clikae pool seed
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profiles to seed"* ]]
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
