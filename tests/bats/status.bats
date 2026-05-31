#!/usr/bin/env bats
# tests/bats/status.bats — `clikae status`

load '../helpers'

@test "status reports nothing when there are no profiles" {
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profiles yet"* ]]
}

@test "status shows (default) when the env var is unset" {
  clikae init claude work
  unset CLAUDE_CONFIG_DIR
  run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"(default)"* ]]
}

@test "status resolves a path env var to its profile (env-dir)" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="$CLIKAE_HOME/profiles/claude/work" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"work"* ]]
}

@test "status reports (external) when the path is not a clikae profile" {
  clikae init claude work
  CLAUDE_CONFIG_DIR="/tmp/not-a-clikae-profile" run clikae status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"(external)"* ]]
}

@test "status resolves an env-var strategy (aws) to the profile name" {
  clikae init aws work
  AWS_PROFILE="work" run clikae status aws
  [ "$status" -eq 0 ]
  [[ "$output" == *"aws"* ]]
  [[ "$output" == *"work"* ]]
}

@test "status with no args lists every CLI that has a profile" {
  clikae init claude work
  clikae init gh personal
  unset CLAUDE_CONFIG_DIR GH_CONFIG_DIR
  run clikae status
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"gh"* ]]
}
