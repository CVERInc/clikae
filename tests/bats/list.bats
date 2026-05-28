#!/usr/bin/env bats
# tests/bats/list.bats — `clikae list`

load '../helpers'

@test "list reports nothing when there are no profiles" {
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profiles yet"* ]]
}

@test "list shows created profiles" {
  clikae init claude work
  clikae init gh personal
  run clikae list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"work"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"personal"* ]]
}

@test "list -p includes the profile path" {
  clikae init claude work
  run clikae list -p
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CLIKAE_HOME/profiles/claude/work"* ]]
}

@test "list output is sorted" {
  clikae init claude zzz
  clikae init claude aaa
  run clikae list
  [ "$status" -eq 0 ]
  # aaa must appear before zzz
  [[ "$output" == *aaa*zzz* ]]
}
