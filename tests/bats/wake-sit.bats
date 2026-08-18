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
  # log.sh first: wake_sit reports its outcome with the family's badges, and
  # bin/clikae has them loaded long before it gets here. Sourcing wake.sh alone
  # is a fixture thinner than the thing it stands for — the same gap that bit
  # wake.bats, which is why both now load what production loads.
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
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
_tankname() { printf 'ckt%s%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

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

@test "sit: nudges the ENGINE window even when the wake window is the active one" {
  # The waiter lives in a `wake` window and the user is told to watch it there, so
  # at reset time that window can be the session's ACTIVE one. A bare `-t <session>`
  # resolves to the CURRENT window — so the nudge would land in the waiter's own
  # pane and the engine would never resume. This pins that it reaches the engine.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local out="$BATS_TEST_TMPDIR/typed"
  # Window 0 is the engine (blocked on read); rename it off the `wake` namespace.
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux rename-window -t "$(_sess):0" claude
  # A second window IS the waiter, and we make it the ACTIVE one — the failing case.
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 30'
  tmux select-window -t "$(_sess):wake"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)"
  [ "$status" -eq 0 ]
  sleep 1
  [ "$(cat "$out")" = "go" ]   # the nudge reached the engine's read, not the wake pane
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
  # NOT `run wait`: bats runs `run` in a subshell, and a background job started in
  # the test body is not its child — so `wait` there always fails with "not a
  # child of this shell", and an assertion of "non-zero" passed no matter what the
  # waiter did. Found while writing the watcher's version of this test.
  local rc=0; wait "$sitter" || rc=$?
  [ "$rc" -ne 0 ]
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
  # `^wake( |$)`, not an exact `wake`: the waiter renames its own window to carry
  # the countdown (`wake 9m`), and on a fast machine that happens before this
  # line runs. An exact match passed on macOS and failed on Linux — a race
  # between two of this feature's own changes, not a second waiter.
  run bash -c "tmux list-windows -t '$(_sess)' -F '#{window_name}' | grep -cE '^wake( |\$)'"
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

@test "attach: a waiter already counting down still blocks a second one" {
  # The guard reads window names, and the waiter RENAMES its own window to carry
  # the countdown. An exact `wake` match therefore stopped matching seconds after
  # the waiter started — and a second limit would have attached a second waiter,
  # with two of them typing into one pane. CI on Linux won that race; macOS lost
  # it and stayed green. This test skips the race entirely by starting from the
  # renamed state.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  tmux new-window -d -t "$(_sess)" -n 'wake 13h38m' 'sleep 30'
  CLIKAE_BIN="$CLIKAE_TEST_ROOT/bin/clikae" wake_attach "$(_sess)" "$(( $(date +%s) + 600 ))"
  run bash -c "tmux list-windows -t '$(_sess)' -F '#{window_name}' | grep -cE '^wake( |\$)'"
  [ "$output" = "1" ]
}

@test "watch: a session that goes dry gets its waiter without anyone running watch" {
  # The gap that let a real limit pass unattended on 2026-08-13: detection lived
  # in `clikae watch` and in the supervised launch (which only runs once the
  # engine has EXITED), so sitting in a live session that hit its limit reached
  # neither. The session watches itself now.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_WATCH_INTERVAL=1
  # A tank that reports dry the moment it is asked, and a reset instant of NOW.
  # Both are stubs on purpose: the phrase-to-instant parser has its own 12 tests
  # and 175-row corpus, and leaving it real here would make this test wait until
  # 3:50am — which it did, once, before the stub was added.
  limit_tank_dry() { printf 'resets 3:50am (Asia/Tokyo)'; return 0; }
  limit_reset_epoch() { date +%s; }
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$BATS_TEST_TMPDIR/typed'; sleep 10"
  sleep 1
  run wake_watch claude "$(_tankname)" "$(_sess)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent \"go\""* ]] || { echo "$output"; false; }
}

@test "watch: a tank with fuel is left alone, and the watcher keeps watching" {
  # The control. A watcher that attached a waiter regardless would pass the test
  # above and be a disaster in practice — it would type into a healthy session.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_WATCH_INTERVAL=1
  limit_tank_dry() { return 1; }
  # Assert on what actually reaches the pane, not on a window name. The first
  # version of this test watched for a window called `wake <time>` — which this
  # setup never creates, since wake_watch is called as a function rather than as
  # a window. It could not have failed: forcing the watcher to ignore dryness
  # entirely left it green.
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 30"
  sleep 1
  wake_watch claude "$(_tankname)" "$(_sess)" >/dev/null &
  local w=$!
  sleep 4
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ ! -f "$out" ]                        # nothing was typed into a healthy session
}

@test "watch: a dry tank whose phrase has no time schedules nothing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_WATCH_INTERVAL=1
  limit_tank_dry() { printf 'resets sometime soon'; return 0; }
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 30"
  sleep 1
  wake_watch claude "$(_tankname)" "$(_sess)" >/dev/null &
  local w=$!
  sleep 4
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ ! -f "$out" ]                        # a guessed time would be worse than none
}

@test "watch: the watcher ends with the session rather than outliving it" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_WATCH_INTERVAL=1
  limit_tank_dry() { return 1; }
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  wake_watch claude "$(_tankname)" "$(_sess)" >/dev/null &
  local w=$!
  sleep 2
  tmux kill-session -t "$(_sess)"
  local rc=0; wait "$w" || rc=$?        # see the note above: never `run wait`
  [ "$rc" -eq 0 ]                        # returned cleanly, not still looping
}

@test "watch: the watcher leaves when the ENGINE window closes, not only when the session dies" {
  # The test above kills the whole SESSION, which trips wake_watch's has-session
  # exit. The OTHER exit — "I am the last window left, the engine is gone" — was
  # never exercised, and it had been dead since it shipped: written with the
  # inside-single-quotes idiom at top level, tmux got -F "'#{window_name}'" and
  # grep got the pattern "'^wake( |\$)'" (a `^` mid-string that matches nothing),
  # so `grep -qv` succeeded on every input and the condition was constant-true.
  # The watcher then looped forever, keeping a dead session alive — and the next
  # launch onto that session name found has-session true, started no engine, and
  # dropped the user into the countdown window with nothing to type into.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  WAKE_WATCH_INTERVAL=1
  limit_tank_dry() { return 1; }              # never dry: only the window guard can end this
  # An engine window plus the waiter's own `wake` window — the real shape.
  #
  # 🔴 The `wake` window sleeps far LONGER than this test runs, on purpose. With a
  # short sleep the session dies on its own and wake_watch's OTHER exit
  # (has-session) ends the loop anyway — so the test would pass on the broken
  # guard too, just slower. It has to be impossible to leave except through the
  # window guard, and the verdict has to be time-bounded.
  tmux new-session -d -s "$(_sess)" -n claude 'sleep 300'
  tmux new-window -d -t "$(_sess)" -n wake 'sleep 300'
  wake_watch claude "$(_tankname)" "$(_sess)" >/dev/null &
  local w=$!
  sleep 2
  tmux kill-window -t "$(_sess):claude"       # the engine exits; only `wake` remains
  # It must notice within a few poll intervals. Broken guard => still looping here.
  local i left=1
  for ((i = 0; i < 10; i++)); do
    if ! kill -0 "$w" 2>/dev/null; then left=0; break; fi
    sleep 1
  done
  if [ "$left" -ne 0 ]; then
    kill "$w" 2>/dev/null || true
    tmux kill-session -t "$(_sess)" 2>/dev/null || true
    false                                     # still watching a session with no engine
  fi
  local rc=0; wait "$w" || rc=$?              # see the note above: never `run wait`
  [ "$rc" -eq 0 ]                             # left cleanly instead of looping forever
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
}

@test "ask: a launch asks once, on a real terminal, and remembers the answer" {
  # Driven through a pty rather than as a unit call: wake_ask_once deliberately
  # stays silent unless both ends are a terminal, and bats captures stdout — so a
  # direct call can only ever exercise the silent branch. This launches clikae the
  # way a person does, answers the question, and checks what was written down.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  clikae init codex "$(_tankname)"
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/codex"
#!/usr/bin/env bash
sleep 20
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/codex"
  rm -f "$CLIKAE_HOME/wake-on-reset"          # the state a first-ever launch is in

  run python3 - "$CLIKAE_BIN" "$(_tankname)" <<'PYEOF'
import os, pty, fcntl, termios, struct, sys, time
clikae, tank = sys.argv[1], sys.argv[2]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2): os.dup2(slave, fd)
    os.close(master); os.close(slave)
    os.environ["TERM"] = "xterm-256color"
    os.execv(clikae, [clikae, "codex", tank])
os.close(slave)
seen = b""
deadline = time.time() + 15
while time.time() < deadline and b"automatically" not in seen:
    try:
        d = os.read(master, 4096)
    except OSError:
        break
    if not d: break
    seen += d
print("PROMPT", "yes" if b"automatically" in seen else "no")
os.write(master, b"n\n")                     # decline, so nothing is scheduled
time.sleep(2)
os.kill(pid, 9)
PYEOF

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"PROMPT yes"* ]] || { echo "$output"; false; }
  [ "$(cat "$CLIKAE_HOME/wake-on-reset" 2>/dev/null | tr -d '[:space:]')" = "off" ]
  tmux kill-session -t "ck-codex-$(_tankname)" 2>/dev/null || true
}

@test "ask: with nobody to answer, nothing is asked and nothing is assumed" {
  # A pipe, CI, a headless run. Staying silent AND leaving the preference unset
  # is the safe direction: this feature types into a live session, so an
  # unanswered question has to mean no.
  _src_wake
  rm -f "$CLIKAE_HOME/wake-on-reset"
  confirm() { echo "ASKED"; return 0; }
  # 🔴 NOT `run bash -c 'wake_ask_once …'`. That spawns a fresh shell, and shell
  # functions do not cross a fork: measured 2026-08-16, both wake_ask_once and
  # the confirm() stub above report NOT-VISIBLE inside it. So this test used to
  # assert that a "command not found" message does not contain the word ASKED —
  # true no matter what wake_ask_once does, including asking every time and
  # typing into a live session. It passed for two months without once running
  # the function it names. Call it here, in the shell that has the stub.
  run wake_ask_once claude work < /dev/null
  [[ "$output" != *ASKED* ]] || { echo "$output"; false; }
  [ "$(wake_pref_get)" = "unset" ]
}
