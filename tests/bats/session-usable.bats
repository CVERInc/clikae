#!/usr/bin/env bats
# tests/bats/session-usable.bats — "the session exists" is not "the session works".
#
# 🔴 THE REPORT. "I had to press left-arrow to find you again." The wake waiter
# lives in a WINDOW OF THE TANK'S OWN SESSION, so when the engine exits — quit or
# crashed — the session survives with only the waiter in it. wake_watch notices
# and leaves, but it polls every WAKE_WATCH_INTERVAL (60s). In that minute:
#
#   clikae <tank>
#     -> has-session          -> true   (the waiter is holding it open)
#     -> so no engine spawned
#     -> attach               -> a countdown, with nothing to type into
#
# switch only ever asked whether the session EXISTED. These pin the other
# question: does it still hold something you can talk to.

load '../helpers'

_src() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  ISO="$TEST_HOME/su-sock"; mkdir -p "$ISO"
  export TMUX_TMPDIR="$ISO"; unset TMUX
  _t() { env -u TMUX TMUX_TMPDIR="$ISO" tmux "$@"; }
}

teardown() {
  [ -n "${ISO:-}" ] && env -u TMUX TMUX_TMPDIR="$ISO" tmux kill-server 2>/dev/null
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
  return 0
}

@test "usable: a session with an engine window is usable" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _t new-session -d -s 'clikae-claude-u' -n claude 'sleep 30'
  run tmux_sess_has_engine 'clikae-claude-u'
  [ "$status" -eq 0 ] || { echo "called a working session unusable"; false; }
}

@test "usable: a session with ONLY the waiter is not" {
  # The 60-second hole, as a test.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _t new-session -d -s 'clikae-claude-u' -n wake 'sleep 30'
  run tmux_sess_has_engine 'clikae-claude-u'
  [ "$status" -ne 0 ] || { echo "a session holding only a countdown was called usable"; false; }
}

@test "usable: the waiter's RENAMED window still counts as the waiter" {
  # 🔴 The waiter renames its own window as it counts (`wake 9m`), so an exact
  # match on `wake` stops working seconds after it starts — and the session would
  # be called usable again while still holding nothing but a countdown.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _t new-session -d -s 'clikae-claude-u' -n wake 'sleep 30'
  _t rename-window -t '=clikae-claude-u:wake' 'wake 9m'
  run tmux_sess_has_engine 'clikae-claude-u'
  [ "$status" -ne 0 ] || { echo "'wake 9m' was not recognised as the waiter"; false; }
}

@test "usable: a window merely STARTING with wake is not the waiter" {
  # `wakeup`, `wake-service` — someone else's window, and calling the session
  # unusable would make clikae kill it. The pattern anchors on a boundary.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _t new-session -d -s 'clikae-claude-u' -n wakeup 'sleep 30'
  run tmux_sess_has_engine 'clikae-claude-u'
  [ "$status" -eq 0 ] || { echo "'wakeup' was mistaken for the waiter"; false; }
}

@test "usable: a neighbour with a longer name is not consulted" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  _t new-session -d -s 'clikae-claude-u-1492' -n claude 'sleep 30'
  _t new-session -d -s 'clikae-claude-u' -n wake 'sleep 30'
  run tmux_sess_has_engine 'clikae-claude-u'
  [ "$status" -ne 0 ] || {
    echo "answered from the digest-suffixed neighbour — the target is not exact"; false; }
}

@test "usable: a session that does not exist is not usable" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  run tmux_sess_has_engine 'clikae-claude-nosuch'
  [ "$status" -ne 0 ]
}

@test "usable: switch rebuilds a session left holding only its waiter" {
  # End to end, on the real command: the thing the user hit.
  #
  # 🔴 Observed WHILE it runs, not after. _pty_run waits for the child, and the
  # child is the attach — so by the time it returns the stub engine has exited,
  # its window has closed, the session is gone and so is the server. The first
  # version of this test asserted against that emptiness and reported "still only
  # a waiter", which was true and meant nothing.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src
  clikae init claude su
  # Stand in for a tank whose engine exited while the waiter held the session.
  _t new-session -d -s 'clikae-claude-su' -n wake 'sleep 120'

  mkdir -p "$TEST_HOME/bin"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$TEST_HOME/bin/claude"
  chmod +x "$TEST_HOME/bin/claude"

  PATH="$TEST_HOME/bin:$PATH" _pty_run "$CLIKAE_BIN" claude su >/dev/null 2>&1 &
  local runner=$!

  local i engines=0
  for i in $(seq 1 40); do
    engines="$(_t list-windows -t '=clikae-claude-su:' -F '#{window_name}' 2>/dev/null \
      | grep -cvE '^wake( |$)' || true)"
    [ "${engines:-0}" -ge 1 ] && break
    sleep 0.5
  done

  local sess wins
  sess="$(_t list-sessions -F '#{session_name}' 2>&1 | tr '\n' ' ')"
  wins="$(_t list-windows -t '=clikae-claude-su:' -F '#{window_name}' 2>&1 | tr '\n' ' ')"
  kill "$runner" 2>/dev/null || true

  [ "${engines:-0}" -ge 1 ] || {
    echo "sessions on the server: [$sess]"
    echo "windows in clikae-claude-su: [$wins]"
    echo "no engine window appeared — the human would be staring at a countdown"; false; }
}
