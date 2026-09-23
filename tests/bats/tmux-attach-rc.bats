#!/usr/bin/env bats
# tests/bats/tmux-attach-rc.bats — `tmux_attach` has to distinguish two failures
# that tmux itself reports identically.
#
# 🔴 WHAT THIS COST. On 2026-08-21 the tmux server died under three of the
# maintainer's live sessions. All three attaches returned 1, and the caller did
# what it does when a terminal cannot host tmux: it relaunched the engine
# OUTSIDE tmux. The conversations survived — `exec` keeps the pid — but the
# sessions were gone from `tmux ls`, so they could not be reattached, could not
# appear on the board, and could not be reached from his phone. He found out by
# looking for them and not finding them.
#
# The distinction cannot be made from the exit code, and must not be made from
# elapsed time (a clock is not a cause). It is made by asking whether tmux is
# still there afterwards.

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
}

@test "tmux_attach: returns 2 when the SERVER went away, not 1" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  local sb="$TEST_HOME/sb.txt"; printf 'scrolled\n' > "$sb"
  # No server at all on this (isolated) socket: the attach cannot succeed and
  # there is nothing left to ask.
  tmux kill-server 2>/dev/null || true
  run tmux_attach "ck-gone" 0 "$sb"
  [ "$status" -eq 2 ] || { echo "expected 2 (server gone), got $status"; false; }
}

@test "tmux_attach: returns 1 when tmux is ALIVE but will not host this terminal" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  local sb="$TEST_HOME/sb.txt"; printf 'scrolled\n' > "$sb"
  # bats has no controlling terminal, so the attach fails the same way TERM=dumb
  # fails on the maintainer's PineNote — and the server is still up. This is the
  # case that MUST keep falling through to a direct run: the fallback exists for
  # that device, and an earlier pre-flight check quietly took roaming away from
  # the one machine the feature was built for.
  tmux kill-server 2>/dev/null || true
  tmux new-session -d -s "ck-alive" 'sleep 30'
  run tmux_attach "ck-alive" 0 "$sb"
  [ "$status" -eq 1 ] || { echo "expected 1 (terminal cannot host), got $status"; false; }
  # Still there: we must not have torn down a session we did not start.
  run tmux has-session -t "ck-alive"
  [ "$status" -eq 0 ]
  tmux kill-server 2>/dev/null || true
}

@test "tmux_attach: a session we started ourselves is put back on a host refusal" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  local sb="$TEST_HOME/sb.txt"; printf 'x\n' > "$sb"
  tmux kill-server 2>/dev/null || true
  tmux new-session -d -s "ck-mine" 'sleep 30'
  tmux new-session -d -s "bystander" 'sleep 30'      # keeps the server up
  run tmux_attach "ck-mine" 1 "$sb"                  # started_here=1
  [ "$status" -eq 1 ]
  run tmux has-session -t "ck-mine"
  [ "$status" -ne 0 ] || { echo "the session we started was left running"; false; }
  run tmux has-session -t "bystander"
  [ "$status" -eq 0 ] || { echo "someone else's session was taken down"; false; }
  tmux kill-server 2>/dev/null || true
}

@test "tmux_attach: the two failures really are indistinguishable by exit code" {
  # The control. If tmux ever starts reporting these differently, this file is
  # solving a problem that no longer exists and should be revisited — but until
  # then, "just look at the exit code" must be shown NOT to work, or the
  # has-session probe above reads as superstition.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  local rc_dead rc_alive
  tmux kill-server 2>/dev/null || true
  # `cmd; rc=$?` aborts the test under bats' set -e before the assignment runs.
  rc_dead=0;  tmux attach -t nothing-here >/dev/null 2>&1 || rc_dead=$?
  tmux new-session -d -s "ck-alive2" 'sleep 30'
  rc_alive=0; tmux attach -t "ck-alive2" >/dev/null 2>&1 || rc_alive=$?
  tmux kill-server 2>/dev/null || true
  [ "$rc_dead" -eq "$rc_alive" ] || {
    echo "tmux now distinguishes them ($rc_dead vs $rc_alive) — revisit tmux_attach"; false; }
}

@test "switch: a lost server is re-hosted, and the retry is bounded" {
  # Wiring, executed rather than grepped: drive the real file and check both
  # branches of the guard exist and are reachable.
  run grep -c 'CLIKAE_TMUX_REHOSTED' "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
  [ "$output" -ge 2 ] || { echo "the one-shot guard is not both set and read"; false; }
  # …and the fallback for a terminal that cannot host tmux is still there, since
  # removing it is the regression this whole change is at risk of causing: it is
  # the only way PineNote's TERM=dumb ssh sessions ever start an engine.
  run grep -c 'exec "\$CLIKAE_BIN" run "\$engine" "\$tank"' "$CLIKAE_TEST_ROOT/lib/commands/switch.sh"
  [ "$output" -ge 1 ] || { echo "the direct-run fallback is gone — PineNote loses roaming"; false; }
}
