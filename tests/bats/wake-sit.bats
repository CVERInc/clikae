#!/usr/bin/env bats
# tests/bats/wake-sit.bats — the waiter, end to end, against a real tmux session.
#
# In production this thing sleeps for hours and then acts once, which is the
# worst shape a gate can have: nobody ever sees it fail. It is testable anyway
# because the instant it waits for is an ARGUMENT — these tests hand it a target
# a second or two out and watch the real loop run, real capture-pane, real
# send-keys. Nothing here is mocked except the clock's distance.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_wake() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
  # Compress the production timings. The VALUES are asserted in wake.bats; here
  # we are testing the loop's shape, and an honest 60s buffer would just make
  # every test in this file a minute long.
  WAKE_BUFFER_SECONDS=1
  WAKE_RETRY_MAX=2
  WAKE_RETRY_BACKOFF=1
}

_sess() { printf 'cksit-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "sit: waits for the instant, then types into the session" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent \"go\""* ]] || false
  sleep 1
  [ "$(cat "$out")" = "go" ]
}

@test "sit: does NOT type early — nothing arrives before the instant" {
  # Without this, a waiter that ignored its target entirely would pass the test
  # above: it would send immediately and the assertion would still hold.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  wake_sit "$(_sess)" "$(( $(date +%s) + 4 ))" >/dev/null &
  local sitter=$!
  sleep 2
  [ ! -f "$out" ]          # 2s in, target is 5s out: still nothing typed
  wait "$sitter" || true
  sleep 1
  [ "$(cat "$out")" = "go" ]
}

@test "sit: a busy pane is retried and then given up on, without typing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # A pane that never stops painting is never idle. It also consumes stdin, so
  # if the waiter typed anyway there would be no trace — hence the assertion is
  # on the waiter's own verdict, and on it terminating rather than looping.
  tmux new-session -d -s "$(_sess)" 'while :; do date +%s.%N; sleep 0.1; done'
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gave up"* ]] || false
  [[ "$output" == *"Nothing was sent"* ]] || false
}

@test "sit: a session that disappears mid-wait ends the waiter, not the machine" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  sleep 1
  wake_sit "$(_sess)" "$(( $(date +%s) + 3 ))" >/dev/null &
  local sitter=$!
  sleep 1
  tmux kill-session -t "$(_sess)"
  run wait "$sitter"
  [ "$status" -ne 0 ]
}

@test "attach: the waiter is a window inside the session it waits on" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae" run wake_attach "$(_sess)" "$(( $(date +%s) + 600 ))"
  [ "$status" -eq 0 ]
  run tmux list-windows -t "$(_sess)" -F '#{window_name}'
  [[ "$output" == *wake* ]] || false
}

@test "attach: a second limit does not stack a second waiter on one session" {
  # Two waiters typing into one pane would send "gogo" — or send twice, minutes
  # apart, into a conversation that had already resumed.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  local e; e="$(( $(date +%s) + 600 ))"
  CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae" wake_attach "$(_sess)" "$e"
  CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae" wake_attach "$(_sess)" "$e"
  run bash -c "tmux list-windows -t '$(_sess)' -F '#{window_name}' | grep -cx wake"
  [ "$output" = "1" ]
}

@test "attach: refuses a session that does not exist instead of creating one" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  run wake_attach "cksit-nope-$$" "$(( $(date +%s) + 600 ))"
  [ "$status" -ne 0 ]
  run tmux has-session -t "cksit-nope-$$"
  [ "$status" -ne 0 ]
}

@test "wake: the preference is one-shot overridable without being persisted" {
  _src_wake
  wake_pref_set off
  CLIKAE_WAKE=on run wake_enabled
  [ "$status" -eq 0 ]                # the flag wins for this run
  CLIKAE_WAKE=off run wake_enabled
  [ "$status" -ne 0 ]                # in both directions
  run wake_enabled
  [ "$status" -ne 0 ]                # and without it, the stored preference rules
  [ "$(wake_pref_get)" = "off" ]     # the override wrote nothing down
}
