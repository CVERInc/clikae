#!/usr/bin/env bats
# tests/bats/info.bats — `clikae info` human + --json output.

load '../helpers'

@test "info shows version, paths, and a profile count" {
  run clikae info
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae"* ]] || false
  [[ "$output" == *"install root"* ]] || false
  [[ "$output" == *"tank store"* ]] || false
  [[ "$output" == *"adapters"* ]] || false
  [[ "$output" == *"tanks"* ]] || false
  # Adapters render comma-space separated, not paste's alternating delimiter.
  [[ "$output" != *",az "* ]] || false
}

@test "info --json emits a valid object with the same facts" {
  run clikae info --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null

  [[ "$output" == *'"version":'* ]] || false
  [[ "$output" == *'"installRoot":'* ]] || false
  [[ "$output" == *'"profileStore":'* ]] || false
  [[ "$output" == *'"shellRc":'* ]] || false
  [[ "$output" == *'"platform":'* ]] || false
  [[ "$output" == *'"adapters":'* ]] || false
  # No profiles yet → count is 0.
  [[ "$output" == *'"profiles": 0'* ]] || false
}

@test "info --json profile count reflects created profiles" {
  clikae init claude a
  clikae init codex work
  run clikae info --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"profiles": 2'* ]] || false
}

@test "info rejects unexpected arguments" {
  run clikae info --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]] || false
}
