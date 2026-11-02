#!/usr/bin/env bats
# tests/bats/make-launcher.bats: contrib/make-launcher.sh (macOS only; skipped elsewhere)

load '../helpers'

macos_only() { [ "$(uname -s)" = "Darwin" ] || skip "the launcher is macOS-only"; }
script() { "$CLIKAE_TEST_ROOT/contrib/make-launcher.sh" "$@"; }

@test "a tank launcher runs clikae for that tank, and its signature verifies" {
  macos_only
  run script claude work --terminal terminal --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run osadecompile "$TEST_HOME/Apps/claude (work).app"
  [[ "$output" == *'do script "clikae claude work"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'custom title of newTab to "claude (work)"'* ]] || { echo "$output"; false; }
  run codesign --verify "$TEST_HOME/Apps/claude (work).app"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a board launcher opens the board and keeps a shell after it" {
  macos_only
  run script --board --terminal terminal --out "$TEST_HOME/Apps"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run osadecompile "$TEST_HOME/Apps/clikae.app"
  [[ "$output" == *'clikae; exec zsh -i'* ]] || { echo "$output"; false; }
}

@test "an existing launcher is replaced only with --force" {
  macos_only
  script claude work --terminal terminal --out "$TEST_HOME/Apps"
  run script claude work --terminal terminal --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
  run script claude work --terminal terminal --out "$TEST_HOME/Apps" --force
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a bad terminal or a name that would reach the shell is refused" {
  macos_only
  run script claude work --terminal warp --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown terminal"* ]] || false
  run script claude 'a;b' --terminal terminal --out "$TEST_HOME/Apps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a tank name"* ]] || false
  [ ! -e "$TEST_HOME/Apps/claude (a;b).app" ]
}
