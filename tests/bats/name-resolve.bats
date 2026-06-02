#!/usr/bin/env bats
# tests/bats/name-resolve.bats — bare `clikae <name>` (scheme B): a tank's NAME is
# its identity, so you can switch to it without naming the engine. Unique name ->
# switch; same name in two engines -> ambiguous, list + non-zero.

load '../helpers'

_stub() { # put a stub engine on PATH that echoes how it was invoked
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "RAN %s $*"\n' "$1" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "clikae <name> resolves a unique tank name and switches to it" {
  _stub claude
  clikae init claude cver
  run clikae cver
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN claude"* ]] || false
}

@test "clikae <name> picks the right engine across engines" {
  _stub codex
  clikae init claude cver
  clikae init codex main
  run clikae main
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN codex"* ]] || false
}

@test "an ambiguous name (same in two engines) is rejected with both options" {
  _stub claude; _stub codex
  clikae init claude shared
  clikae init codex shared
  run clikae shared
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ambiguous"* ]] || false
  [[ "$output" == *"clikae claude shared"* ]] || false
  [[ "$output" == *"clikae codex shared"* ]] || false
}

@test "an unknown token reports the error and falls back to help" {
  run clikae definitely-not-a-tank
  # It prints the error (to stderr, merged by bats) then shows help (exit 0).
  [[ "$output" == *"Unknown command, engine, or tank"* ]] || false
}

@test "a bare engine name still switches (regression: dispatcher order)" {
  _stub claude
  clikae init claude work
  run clikae claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN claude"* ]] || false
}
