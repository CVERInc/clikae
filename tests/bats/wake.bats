#!/usr/bin/env bats
# tests/bats/wake.bats — the gate that stands between "the limit lifted" and
# typing into somebody's live session.
#
# The gate is the whole risk of the feature: a nudge that lands in a dead pane,
# a vanished session, or the middle of a running tool call goes somewhere nobody
# intended. So the happy path is the least interesting test here — most of these
# assert that it REFUSES.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_wake() {
  # wake_offer reaches for limit_reset_epoch and the log helpers, exactly as
  # bin/clikae has them loaded by then. Sourcing wake.sh alone passed the pure
  # tmux tests and failed the moment a test touched wake_offer — a fixture
  # thinner than the thing it stands in for.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
}

_sess() { printf 'ckwake-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  # These tests create REAL tmux sessions, which outlive $TEST_HOME. Kill ours
  # first, then let the shared teardown remove the throwaway home.
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "wake: a quiet session is safe to type into" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 60'
  run wake_pane_idle "$(_sess)" 1
  [ "$status" -eq 0 ]
}

@test "wake: a session still painting the screen is NOT idle" {
  # The control this test exists to be: if wake_pane_idle only checked that the
  # session exists, the test above would pass and so would this one.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'while :; do date +%s.%N; sleep 0.1; done'
  sleep 1
  run wake_pane_idle "$(_sess)" 1
  [ "$status" -ne 0 ]
}

@test "wake: a session that never existed is refused" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  run wake_pane_idle "ckwake-no-such-session-$$" 1
  [ "$status" -ne 0 ]
}

@test "wake: an empty session name is refused rather than sent somewhere" {
  # Honest about what this does and does not prove: deleting our own `[ -n ]`
  # check leaves this green, because tmux refuses an empty target too. So this
  # asserts the OUTCOME (nothing is typed anywhere) and not our guard. The guard
  # stays because it does not depend on tmux keeping that behaviour.
  _src_wake
  run wake_pane_idle "" 1
  [ "$status" -ne 0 ]
  run wake_send ""
  [ "$status" -ne 0 ]
}

@test "wake: a dead pane is refused even though the session is still listed" {
  # remain-on-exit keeps the window after its process dies — the session answers
  # has-session, and a gate that stopped there would happily type into a corpse.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 60'
  # remain-on-exit is a WINDOW option; setting it without -w silently targets the
  # wrong scope and the pane disappears on exit, which turns this test into the
  # "session is gone" one it is supposed to be distinct from.
  tmux set-option -w -t "$(_sess)" remain-on-exit on
  tmux respawn-pane -k -t "$(_sess)" 'true'
  sleep 1
  # Precondition: the session must still be listed, or this proves nothing.
  tmux has-session -t "$(_sess)" 2>/dev/null
  [ "$(tmux display-message -p -t "$(_sess)" '#{pane_dead}')" = "1" ]
  run wake_pane_idle "$(_sess)" 1
  [ "$status" -ne 0 ]
}

@test "wake: the nudge actually reaches the pane" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 5"
  sleep 1
  run wake_send "$(_sess)"
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$out" ]
  [ "$(cat "$out")" = "go" ]
}

@test "wake: sending to a session that is gone fails instead of succeeding quietly" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  run wake_send "ckwake-no-such-session-$$"
  [ "$status" -ne 0 ]
}

@test "wake: the buffer is the measured one, not a round guess" {
  # 60s is twice the smallest observed lead (+30s, six times across 116 clean
  # outage windows). If someone edits it to a bigger "safe" number, the reason
  # should have to be re-argued rather than drifting.
  _src_wake
  [ "$WAKE_BUFFER_SECONDS" -ge 30 ]
  [ "$WAKE_BUFFER_SECONDS" -le 300 ]
  [ "$WAKE_RETRY_MAX" -ge 1 ]
  [ "$WAKE_RETRY_MAX" -le 5 ]
}

@test "offer: with no live session there is nothing to wait for, and it says nothing" {
  # The supervised path runs after the engine has EXITED, which took its session
  # with it. A waiter there would be counting down to type into nothing.
  _src_wake
  wake_pref_set on
  run wake_offer claude no-such-tank "resets 3:50am (Asia/Tokyo)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offer: a dry tank with no time in the vendor's sentence schedules nothing" {
  _src_wake
  wake_pref_set on
  run wake_offer claude no-such-tank ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offer: preference off means it never attaches, session or not" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_pref_set off
  tmux new-session -d -s "ck-claude-$(_sess)" 'sleep 20'
  run wake_offer claude "$(_sess)" "resets 3:50am (Asia/Tokyo)"
  tmux kill-session -t "ck-claude-$(_sess)" 2>/dev/null || true
  [ -z "$output" ]
}

@test "offer: on a live session with a real phrase, the waiter is attached" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_pref_set on
  local s="ck-claude-$(_sess)"
  tmux new-session -d -s "$s" 'sleep 20'
  CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae" wake_offer claude "$(_sess)" "resets 3:50am (Asia/Tokyo)" >/dev/null
  run bash -c "tmux list-windows -t '$s' -F '#{window_name}' | grep -c '^wake'"
  tmux kill-session -t "$s" 2>/dev/null || true
  [ "$output" = "1" ]
}

@test "offer: with nothing to attach to, you are not asked a pointless question" {
  # The reason the session check comes FIRST. Removing it leaves every outcome
  # test green — wake_attach refuses anyway — while quietly introducing a prompt
  # about resuming a session that does not exist. `confirm` is stubbed to fail
  # loudly if it is ever reached.
  _src_wake
  rm -f "$CLIKAE_HOME/wake-on-reset"          # preference unset -> would ask
  confirm() { echo "ASKED"; return 0; }
  run wake_offer claude no-such-tank "resets 3:50am (Asia/Tokyo)"
  [[ "$output" != *ASKED* ]] || false
  [ "$(wake_pref_get)" = "unset" ]            # and nothing was recorded
}
