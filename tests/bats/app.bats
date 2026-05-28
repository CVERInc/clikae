#!/usr/bin/env bats
# tests/bats/app.bats — `clikae app` (macOS only; skipped elsewhere)

load '../helpers'

macos_only() { [ "$(uname -s)" = "Darwin" ] || skip "clikae app is macOS-only"; }

@test "app generates a .app bundle" {
  macos_only
  clikae init claude work
  run clikae app claude work --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/claude (work).app" ]
}

@test "app refuses to overwrite an existing .app without --force" {
  macos_only
  clikae init claude work
  clikae app claude work --out "$TEST_HOME/Apps"
  run clikae app claude work --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "app overwrites an existing .app with --force" {
  macos_only
  clikae init claude work
  clikae app claude work --out "$TEST_HOME/Apps"
  run clikae app claude work --out "$TEST_HOME/Apps" --force
  [ "$status" -eq 0 ]
  [ -d "$TEST_HOME/Apps/claude (work).app" ]
}

@test "app fails for a missing profile" {
  macos_only
  run clikae app claude ghost --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Profile not found"* ]]
}
