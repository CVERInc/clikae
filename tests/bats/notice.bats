#!/usr/bin/env bats
# tests/bats/notice.bats — the one-time cross-account-carry note
# (lib/core/notice.sh). Informed consent, not a nag: shown once per store,
# never blocks a non-TTY run.

load '../helpers'

_source_notice() {
  CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=../../lib/core/notice.sh
  source "$CLIKAE_LIB/core/notice.sh"
}

@test "carry_notice_once prints the note and creates the marker on first call" {
  _source_notice
  run carry_notice_once
  [ "$status" -eq 0 ]
  [[ "$output" == *"one-time note about your accounts"* ]] || false
  [[ "$output" == *"terms-and-your-accounts"* ]] || false
  [ -f "$CLIKAE_HOME/carry-notice-shown" ]
}

@test "carry_notice_once is silent on every later call" {
  _source_notice
  carry_notice_once >/dev/null 2>&1
  run carry_notice_once
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "carry_notice_once never blocks without a TTY (bats stdin is not one)" {
  _source_notice
  # If it tried to read stdin interactively this would hang; bats' timeout-free
  # completion of this test IS the assertion, plus no prompt text in output.
  run carry_notice_once
  [ "$status" -eq 0 ]
  [[ "$output" != *"Enter to continue"* ]] || false
}

@test "burn --no-reroute never triggers the note (no cross-account carry armed)" {
  clikae init claude a >/dev/null
  run clikae burn claude a --no-reroute --artifact "$TEST_HOME/x.txt" -- echo hi
  # burn itself may fail later (no real engine) — the assertion is only that
  # the note was neither shown nor marked.
  [ ! -f "$CLIKAE_HOME/carry-notice-shown" ]
}
