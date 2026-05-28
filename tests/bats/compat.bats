#!/usr/bin/env bats
# tests/bats/compat.bats — guard against constructs that break macOS bash 3.2.
#
# macOS ships bash 3.2, so the source must avoid bash 4+ idioms and GNU-isms.
# These are source-scanning meta-tests, not behavioural ones.

load '../helpers'

scan() { grep -rnE "$1" "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib"; }

@test "no mapfile / readarray (bash 4+)" {
  run scan '\b(mapfile|readarray)\b'
  [ -z "$output" ]
}

@test "no \${var,,} / \${var^^} case modification (bash 4+)" {
  run scan '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)'
  [ -z "$output" ]
}

@test "no readlink -f (not on macOS/BSD)" {
  run scan 'readlink[[:space:]]+-f'
  [ -z "$output" ]
}

@test "no &> redirection (use >file 2>&1)" {
  run grep -rn -- '&>' "$CLIKAE_TEST_ROOT/bin/clikae" "$CLIKAE_TEST_ROOT/lib"
  [ -z "$output" ]
}
