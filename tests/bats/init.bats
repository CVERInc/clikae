#!/usr/bin/env bats
# tests/bats/init.bats — `clikae init`

load '../helpers'

@test "init creates the profile directory" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
}

@test "init without --alias does not touch the rc file" {
  run clikae init claude work
  [ "$status" -eq 0 ]
  [ ! -f "$RC_FILE" ]
}

@test "init --alias creates the profile and one alias block" {
  run clikae init claude work --alias
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work" ]
  [ "$(rc_block_count claude.work)" -eq 1 ]
}

@test "init fails for an unknown CLI" {
  run clikae init nosuchcli work
  [ "$status" -ne 0 ]
  [[ "$output" == *"No built-in adapter"* ]]
}

@test "init fails when the profile already exists" {
  clikae init claude work
  run clikae init claude work
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "init rejects a profile name with a leading dot" {
  run clikae init claude .hidden
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]]
}

@test "init rejects a profile name with a slash" {
  run clikae init claude a/b
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]]
}

@test "init accepts a dotted profile name" {
  run clikae init claude work.2
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work.2" ]
}

@test "init accepts a dashed profile name" {
  run clikae init claude work-acct
  [ "$status" -eq 0 ]
  [ -d "$CLIKAE_HOME/profiles/claude/work-acct" ]
}

@test "init seeds an env-file adapter's config file (kubectl)" {
  run clikae init kubectl dev
  [ "$status" -eq 0 ]
  [ -f "$CLIKAE_HOME/profiles/kubectl/dev/config" ]
}
