#!/usr/bin/env bats
# tests/bats/antigravity_keychain_real.bats — exercises the REAL macOS `security`
# binary end to end, against a throwaway scratch keychain (never `login.keychain`).
#
# WHY this file exists: the 2026-06-30 incident that got the Keychain token carry
# ripped out happened because the stash/restore mechanism had NEVER been run
# against a real Keychain — tests/helpers.bash stubs `security` completely for
# every other test (deliberately, so the suite never touches a real login item).
# That stub is order-agnostic and shape-agnostic in ways the real binary is not
# (e.g. it accepted a `-k <path>` flag; the real `security` only takes the
# keychain as a bare TRAILING positional argument — caught by this file during
# development). This file is the actual regression guard for that class of gap.
#
# Safety: everything here runs against `$BATS_TEST_TMPDIR/scratch.keychain`, a
# throwaway file created and destroyed within the test — `_agy_kc_keychain_argv`
# only ever points at an alternate keychain when $CLIKAE_AGY_KEYCHAIN is set,
# which production code (antigravity.sh proper) never does.

load '../helpers'

bats_require_minimum_version 1.5.0

setup() {
  [[ "$OSTYPE" == darwin* ]] || skip "agy Keychain carry is macOS-only"
  command -v security >/dev/null 2>&1 || skip "no 'security' binary on this machine"
  # shellcheck source=../../lib/core/log.sh
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=../../lib/commands/antigravity.sh
  source "$CLIKAE_TEST_ROOT/lib/commands/antigravity.sh"
  SCRATCH_KC="$BATS_TEST_TMPDIR/scratch.keychain"
  security create-keychain -p clikae-test-scratch "$SCRATCH_KC"
  security unlock-keychain -p clikae-test-scratch "$SCRATCH_KC"
  export CLIKAE_AGY_KEYCHAIN="$SCRATCH_KC"
}

teardown() {
  [ -n "${SCRATCH_KC:-}" ] && security delete-keychain "$SCRATCH_KC" 2>/dev/null || true
}

@test "real Keychain: stash then restore round-trips the secret byte-for-byte" {
  security add-generic-password -s "$(_agy_kc_canon_service)" -a "$(_agy_kc_account)" \
    -l canon -w 'super-secret-token' -U "$SCRATCH_KC"
  run _agy_kc_stash tank-a
  [ "$status" -eq 0 ]
  [ "$(_agy_kc_read "$(_agy_kc_tank_service tank-a)")" = "super-secret-token" ]

  # Clear canonical (simulate switching away), then restore tank-a's stash back.
  security delete-generic-password -s "$(_agy_kc_canon_service)" -a "$(_agy_kc_account)" "$SCRATCH_KC"
  run _agy_kc_restore tank-a
  [ "$status" -eq 0 ]
  [ "$(_agy_kc_read "$(_agy_kc_canon_service)")" = "super-secret-token" ]
  run _agy_kc_verify_restore tank-a
  [ "$status" -eq 0 ]
}

@test "real Keychain: restoring a tank with no stash clears canonical (clean logout)" {
  security add-generic-password -s "$(_agy_kc_canon_service)" -a "$(_agy_kc_account)" \
    -l canon -w 'stale-token' -U "$SCRATCH_KC"
  run _agy_kc_restore tank-never-logged-in
  [ "$status" -eq 0 ]
  run ! _agy_kc_read "$(_agy_kc_canon_service)"
  run _agy_kc_verify_restore tank-never-logged-in
  [ "$status" -eq 0 ]   # no stash to verify against -> not a failure
}

@test "real Keychain: verify_restore catches a mismatched/corrupted restore" {
  security add-generic-password -s "$(_agy_kc_tank_service tank-b)" -a "$(_agy_kc_account)" \
    -l tank-b -w 'tank-b-token' -U "$SCRATCH_KC"
  # Simulate the exact 2026-06-30 failure mode: canonical ends up holding a
  # DIFFERENT secret than the tank's stash (as if the copy silently mismatched).
  security add-generic-password -s "$(_agy_kc_canon_service)" -a "$(_agy_kc_account)" \
    -l canon -w 'wrong-token' -U "$SCRATCH_KC"
  run _agy_kc_verify_restore tank-b
  [ "$status" -ne 0 ]
  [[ "$output" == *"didn't verify"* ]] || false
}

@test "real Keychain: rename carries the tank's slot and drops the old name" {
  security add-generic-password -s "$(_agy_kc_tank_service old)" -a "$(_agy_kc_account)" \
    -l old -w 'renamed-token' -U "$SCRATCH_KC"
  run _agy_kc_rename old new
  [ "$status" -eq 0 ]
  [ "$(_agy_kc_read "$(_agy_kc_tank_service new)")" = "renamed-token" ]
  run ! _agy_kc_read "$(_agy_kc_tank_service old)"
}
