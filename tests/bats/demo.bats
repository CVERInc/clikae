#!/usr/bin/env bats
# tests/bats/demo.bats — `clikae demo`, the throwaway-sandbox guided tour.

load '../helpers'

@test "demo runs the full tour end to end" {
  run clikae demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"guided tour"* ]] || false
  [[ "$output" == *"alice@studio.dev"* ]] || false
  [[ "$output" == *"bob@studio.dev"* ]] || false
  [[ "$output" == *"active here"* ]]          # the live tank board, alice active
  [[ "$output" == *"clikae to bob"* ]] || false
}

@test "demo touches nothing in the real CLIKAE_HOME" {
  # A pre-existing profile must be untouched and no demo profiles must leak in.
  clikae init gh personal
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae demo
  [ "$status" -eq 0 ]
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  [ ! -d "$CLIKAE_HOME/profiles/claude/alice" ]
}

@test "demo cleans up its sandbox" {
  run clikae demo
  [ "$status" -eq 0 ]
  # The "Everything below runs under <dir>" line names the sandbox; it must be gone.
  local sb
  sb="$(printf '%s\n' "$output" | sed -n 's/.*runs under \(.*\)$/\1/p' | head -n1)"
  [ -n "$sb" ]
  [ ! -d "$sb" ]
}

@test "demo --help explains the sandbox" {
  run clikae demo --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"sandbox"* ]] || false
}

@test "demo rejects unexpected arguments" {
  run clikae demo bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]] || false
}
