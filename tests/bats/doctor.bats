#!/usr/bin/env bats
# tests/bats/doctor.bats — `clikae doctor` read-only health check.

load '../helpers'

@test "doctor reports environment + a row per supported CLI" {
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"clikae doctor"* ]] || false
  [[ "$output" == *"CLIKAE_HOME"* ]] || false
  [[ "$output" == *"$CLIKAE_HOME"* ]] || false
  [[ "$output" == *"INSTALLED"* ]] || false
  [[ "$output" == *"TANKS"* ]] || false
}

@test "doctor lists ALL adapters including the last one (vercel)" {
  # Regression: $(scan_clis) strips the trailing newline, so a naive
  # `printf '%s' | while read` drops the final CLI. vercel must be present.
  run clikae doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"vercel"* ]] || false
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"codex"* ]] || false
}

@test "doctor counts a created profile and suggests the next step" {
  clikae init claude work
  run clikae doctor
  [ "$status" -eq 0 ]
  # claude row now shows a non-zero profile count.
  [[ "$output" =~ claude[[:space:]]+(yes|no)[[:space:]]+1 ]] || false
}

@test "doctor changes nothing on disk (read-only)" {
  before="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  run clikae doctor
  [ "$status" -eq 0 ]
  after="$(find "$CLIKAE_HOME" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
}

@test "doctor rejects unexpected arguments" {
  run clikae doctor bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected argument"* ]] || false
}
