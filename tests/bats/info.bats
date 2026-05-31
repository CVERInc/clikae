#!/usr/bin/env bats
# tests/bats/info.bats — `clikae info` human + --json output.

load '../helpers'

@test "info shows version, paths, and a profile count" {
  run clikae info
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae"* ]]
  [[ "$output" == *"install root"* ]]
  [[ "$output" == *"profile store"* ]]
  [[ "$output" == *"adapters"* ]]
  [[ "$output" == *"profiles"* ]]
  # Adapters render comma-space separated, not paste's alternating delimiter.
  [[ "$output" != *",az "* ]]
}

@test "info --json emits a valid object with the same facts" {
  run clikae info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null

  [[ "$output" == *'"version":'* ]]
  [[ "$output" == *'"installRoot":'* ]]
  [[ "$output" == *'"profileStore":'* ]]
  [[ "$output" == *'"shellRc":'* ]]
  [[ "$output" == *'"platform":'* ]]
  [[ "$output" == *'"adapters":'* ]]
  # No profiles yet → count is 0.
  [[ "$output" == *'"profiles": 0'* ]]
}

@test "info --json profile count reflects created profiles" {
  clikae init claude a
  clikae init codex work
  run clikae info --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"profiles": 2'* ]]
}

@test "info rejects unexpected arguments" {
  run clikae info --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]]
}
