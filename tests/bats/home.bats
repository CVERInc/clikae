#!/usr/bin/env bats
# tests/bats/home.bats — bare `clikae` opens the home dashboard (tank board /
# welcome), the new default when no subcommand is given.

load '../helpers'

@test "bare clikae with no profiles shows the welcome + first step" {
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]]
  [[ "$output" == *"clikae init"* ]]
  [[ "$output" == *"13 CLIs"* ]]
}

@test "bare clikae with profiles shows the tank board grouped by CLI" {
  clikae init claude work
  clikae init claude personal
  clikae init codex cheap
  run clikae
  [ "$status" -eq 0 ]
  # Header summary: 3 tanks across 2 CLIs.
  [[ "$output" == *"3 tanks across 2 CLIs"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"work"* ]]
  [[ "$output" == *"personal"* ]]
  [[ "$output" == *"codex"* ]]
  # No tank is active in this clean shell — nothing marked "active here".
  [[ "$output" != *"active here"* ]]
}

@test "the tank active in THIS shell is marked" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"active here"* ]]
}

@test "the fuel-pool order is shown when a pool is set" {
  clikae init claude work
  clikae pool add claude/work
  clikae pool add claude/spare
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *"fuel pool"* ]]
  [[ "$output" == *"claude/work → claude/spare"* ]]
}

@test "dashboard is reachable by name and via --help" {
  run clikae dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tanks yet"* ]]

  run clikae home --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"home dashboard"* ]]
}

@test "bare clikae changes nothing on disk (read-only)" {
  clikae init claude work
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae
  [ "$status" -eq 0 ]
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}

@test "an unknown subcommand still falls back to help" {
  run clikae definitely-not-a-command
  [[ "$output" == *"Unknown command"* ]]
  [[ "$output" == *"Commands:"* ]]
}
