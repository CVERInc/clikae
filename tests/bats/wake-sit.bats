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
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/wake.sh"
  # Compress the production timings. The VALUES are asserted in wake.bats; here
  # we are testing the loop's shape, and an honest 60s buffer would just make
  # every test in this file a minute long.
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_BUFFER_SECONDS=1
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_RETRY_MAX=2
  # shellcheck disable=SC2034  # read by the wake loop sourced above
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

@test "sit: a pane that never stops painting is nudged anyway while the tank is dry" {
  # THIS TEST USED TO ASSERT THE OPPOSITE, and the old rule is why the feature
  # fired once in 24 real limits.
  #
  # "The screen is still moving" used to veto the nudge, on the reasoning that
  # movement could be a tool call in flight. It cannot be, here: the waiter only
  # types after the reset instant AND only while the tank still reads dry, and a
  # dry tank has no turn running — the API is refusing them. What a limited
  # engine actually leaves on screen is a banner with a live countdown in it,
  # and a countdown re-renders every second, forever. Measured against the
  # mechanism rather than assumed: a pane whose only change is one ticking line
  # fails wake_pane_idle on every capture pair (that is still pinned by
  # wake.bats' "a session still painting the screen is NOT idle"), while the
  # same banner text held still passes it. So the waiter spent its three
  # attempts and gave up inside five minutes of every reset.
  #
  # The gate that remains is wake_pane_live — a session, and a pane that is not
  # a corpse. Idle is a settle delay and a note in the trace now, not a veto.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local out="$BATS_TEST_TMPDIR/typed"
  # Still dry at the moment of typing: no recovery evidence anywhere.
  wake_tank_recovered() { return 1; }
  # A pane that paints forever AND can still receive the nudge — the old version
  # of this test used a painter that ate stdin, which made "did it type?"
  # unanswerable and left the verdict as the only thing to assert.
  tmux new-session -d -s "$(_sess)" \
    "while :; do date +%s.%N; sleep 0.1; done & read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$(_tankname)"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"sent \"go\""* ]] || { echo "$output"; false; }
  sleep 1
  [ "$(cat "$out")" = "go" ]
}

@test "sit: a dead pane is still given up on — the existence gate was not waived with the idle one" {
  # The control for the test above. Splitting wake_pane_idle into "is there a
  # target" and "has it stopped moving" is only safe if the first half still
  # refuses: a nudge into a corpse goes nowhere and reports success.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  tmux new-session -d -s "$(_sess)" 'sleep 60'
  tmux set-option -w -t "$(_sess)" remain-on-exit on
  tmux respawn-pane -k -t "$(_sess)" 'true'
  sleep 1
  [ "$(tmux display-message -p -t "$(_sess)" '#{pane_dead}')" = "1" ]
  run wake_sit "$(_sess)" "$(date +%s)" claude "$(_tankname)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gave up"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Nothing was sent"* ]] || false
}

@test "sit: a tank the vendor already continued is SKIPPED, not nudged a second time" {
  # The one way this feature can do harm. Claude Code writes its own
  # "usage limit has reset, continue" line within a minute of some resets and
  # then carries on; typing "go" on top of that is a second instruction landing
  # in a conversation that is already working. Real transcript shape, and read
  # through the real limit scanner rather than a stub — the skip is only worth
  # anything if the thing it reads is the thing production reads.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  local proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  mkdir -p "$proj"
  {
    printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 8:20pm (Asia/Tokyo)"}]},"timestamp":"2026-09-16T13:37:00.000Z"}'
    printf '%s\n' '{"parentUuid":"a1","isMeta":true,"type":"user","message":{"role":"user","content":"Your claude.ai usage limit has reset. Continue the task you were working on."},"origin":{"kind":"auto-continuation"},"promptSource":"system","timestamp":"2026-09-16T15:00:30.000Z"}'
  } > "$proj/s.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"resumed on its own"* ]] || { echo "$output"; false; }
  sleep 1
  [ ! -f "$out" ] || { echo "a second nudge was typed: $(cat "$out")"; false; }
  grep -q "skipped" "$CLIKAE_HOME/state/wake/claude-$tank.log"
}

@test "sit: a tank with a limit and NO recovery evidence is still nudged (the skip's control)" {
  # Without this, a waiter that skipped unconditionally would pass the test
  # above — and never type again.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)b"
  local proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  mkdir -p "$proj"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 8:20pm (Asia/Tokyo)"}]},"timestamp":"2026-09-16T13:37:00.000Z"}' > "$proj/s.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  sleep 1
  [ "$(cat "$out")" = "go" ]
}

@test "trace: every outcome outlives the window it was printed in, and clikae wake reads the last one" {
  # The window text was the ONLY account this feature ever gave of itself, and
  # it dies with the session. 24 limit events, one observed nudge, and nobody
  # could name the other 23 outcomes.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  wake_tank_recovered() { return 1; }
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  wake_sit "$(_sess)" "$(date +%s)" claude "$tank" >/dev/null
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ -f "$log" ] || { echo "no trace at $log"; false; }
  grep -q $'\tattached\t' "$log" || { cat "$log"; false; }
  grep -q $'\ttyped\t' "$log" || { cat "$log"; false; }
  # …and the thing a person actually runs surfaces it.
  run "$CLIKAE_BIN" wake
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-$tank"* ]] || { echo "$output"; false; }
  [[ "$output" == *"typed"* ]] || { echo "$output"; false; }
}

@test "trace: a waiter whose session is killed records WHY, where the window cannot" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  tmux new-session -d -s "$(_sess)" 'sleep 30'
  wake_sit "$(_sess)" "$(( $(date +%s) + 3 ))" claude "$tank" >/dev/null &
  local sitter=$!
  sleep 1
  tmux kill-session -t "$(_sess)"
  wait "$sitter" || true                 # see the note below: never `run wait`
  grep -q $'\tsession-gone\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log" 2>/dev/null; false; }
}

@test "trace: the log is capped rather than kept forever" {
  _src_wake
  # shellcheck disable=SC2034  # read by wake_trace, sourced above
  WAKE_LOG_MAX=5
  local i
  for ((i = 0; i < 40; i++)); do
    wake_trace claude capped "sess-$i" "attempt" "row $i"
  done
  local n; n="$(wc -l < "$CLIKAE_HOME/state/wake/claude-capped.log" | tr -d '[:space:]')"
  [ "$n" -le 10 ] || { echo "grew to $n lines"; false; }
  # Capped from the OLD end: the newest row must survive the rotation.
  grep -q "row 39" "$CLIKAE_HOME/state/wake/claude-capped.log"
}

@test "ident: a waiter given only a session name still finds its tank" {
  # wake_attach spells the tank out now, but a waiter left behind by an older
  # binary passes only the session — and without an identity it would write its
  # trace to a stray file and skip the no-double-nudge check entirely.
  _src_wake
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/tmux.sh"
  run wake_ident "${CLIKAE_SESS_PREFIX}claude-my-tank-12345"
  [ "$output" = "$(printf 'claude\037my-tank')" ] || { echo "[$output]"; false; }
  run wake_ident "${CLIKAE_SESS_PREFIX}codex-work"
  [ "$output" = "$(printf 'codex\037work')" ] || { echo "[$output]"; false; }
  # An explicit pair always wins over the parse.
  run wake_ident "${CLIKAE_SESS_PREFIX}claude-x" agy other
  [ "$output" = "$(printf 'agy\037other')" ] || { echo "[$output]"; false; }
  # And a name that is not ours is answered with two EMPTY fields — the
  # separator and nothing else — rather than a guess at somebody's tank.
  run wake_ident "some-other-session"
  [ "$output" = "$(printf '\037')" ] || { echo "[$(printf '%s' "$output" | od -c | head -1)]"; false; }
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
  # shellcheck disable=SC2034  # read by the wake loop sourced above
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
  # shellcheck disable=SC2034  # read by the wake loop sourced above
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
  tmux kill-session -t "clikae-codex-$(_tankname)" 2>/dev/null || true
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

# _phrase_minutes_ago <minutes> -> the vendor's own wording for a reset that
# happened that long ago, in this host's named zone (the parser requires one).
_phrase_minutes_ago() {
  local t z h p
  t="$(( $(date +%s) - $1 * 60 ))"
  z="$(readlink /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')"
  [ -n "$z" ] || return 1
  h="$(date -r "$t" '+%-I:%M' 2>/dev/null || date -d "@$t" '+%-I:%M')"
  p="$(date -r "$t" '+%p' 2>/dev/null || date -d "@$t" '+%p')"
  printf 'resets %s%s (%s)' "$h" "$(printf '%s' "$p" | tr 'APM' 'apm')" "$z"
}

@test "watch: a limit whose stated reset ALREADY passed is nudged now, not a day later" {
  # The watcher polls once a minute and the machine may have been asleep, so it
  # routinely meets a limit whose stated reset is already behind it. An undated
  # phrase names a time of day, so "resets 8:20pm" read at 21:00 used to resolve
  # to 8:20pm TOMORROW — the waiter was handed an instant 23 hours out and the
  # session sat there. This runs the real limit_tank_dry and the real
  # limit_reset_epoch against a real session: nothing about the clock is mocked
  # except how far in the past the phrase is.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  local phrase; phrase="$(_phrase_minutes_ago 10)" || skip "no named zone on this host"
  local tank; tank="$(_tankname)p"
  local proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  mkdir -p "$proj"
  printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · %s"}]},"timestamp":"%s"}\n' \
    "$phrase" "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')" > "$proj/s.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 60"
  sleep 1
  wake_watch claude "$tank" "$(_sess)" >/dev/null &
  local w=$!
  # Bounded on purpose: the regression's symptom is a wait, not a wrong value,
  # and a test that waits for it would wedge the suite rather than fail it.
  local i
  for ((i = 0; i < 20; i++)); do
    [ -s "$out" ] && break
    sleep 1
  done
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ -s "$out" ] || { echo "nothing was typed within 20s (phrase: $phrase)"; false; }
  [ "$(cat "$out")" = "go" ]
  grep -q $'\ttyped\t' "$CLIKAE_HOME/state/wake/claude-$tank.log"
}

@test "watch: a passed reset still does NOT nudge a tank the vendor already continued" {
  # The skip stays in front of the nudge on this path too — the fix above only
  # moved WHEN the waiter acts, never whether it checks first.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  local phrase; phrase="$(_phrase_minutes_ago 10)" || skip "no named zone on this host"
  local tank; tank="$(_tankname)q"
  local proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  mkdir -p "$proj"
  # A limit, then the vendor continuing by itself five minutes later. The tank
  # therefore reads RECOVERED, and limit_tank_dry will not even hand over — but
  # the waiter's own re-check is what this pins, so drive wake_sit directly with
  # the passed instant the watcher would have computed.
  {
    printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · %s"}]},"timestamp":"2026-09-16T13:37:00.000Z"}\n' "$phrase"
    printf '%s\n' '{"parentUuid":"a1","isMeta":true,"type":"user","message":{"role":"user","content":"Your claude.ai usage limit has reset. Continue the task you were working on."},"origin":{"kind":"auto-continuation"},"promptSource":"system","timestamp":"2026-09-16T15:00:30.000Z"}'
  } > "$proj/s.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 30"
  sleep 1
  run wake_sit "$(_sess)" "$(( $(date +%s) - 600 ))" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"resumed on its own"* ]] || { echo "$output"; false; }
  [ ! -f "$out" ] || { echo "typed anyway: $(cat "$out")"; false; }
}
