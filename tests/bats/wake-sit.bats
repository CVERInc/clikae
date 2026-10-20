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
  . "$CLIKAE_TEST_ROOT/lib/core/live.sh"
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
  # The post-send check (#161): two one-second looks, so a test whose pane
  # never answers costs two seconds, not three minutes.
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_VERIFY_SECONDS=2
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_VERIFY_INTERVAL=1
}

# _responder <transcript> <out> <answer>... -> path of a script that stands in
# for the engine: for each line typed into its pane it appends that line to
# <out>, then appends the NEXT answer to <transcript>, stamped with the real
# clock at that moment — `turn` (a real assistant line), `limit` (the
# synthetic refusal Claude writes), or `none`. The last answer repeats.
# A script file rather than an inline tmux command: the JSON's quotes would
# otherwise have to survive three layers of shell.
_responder() {
  local tx="$1" out="$2" f="$BATS_TEST_TMPDIR/responder.sh"; shift 2
  {
    printf '#!/bin/bash\n'
    printf 'tx=%q; out=%q; answers=(%s)\n' "$tx" "$out" "$*"
    cat <<'SH'
i=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$out"
  a="${answers[$i]:-${answers[${#answers[@]}-1]}}"
  i=$((i + 1))
  now="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
  case "$a" in
    turn)  printf '{"type":"assistant","message":{"model":"claude-opus","content":[{"type":"text","text":"Continuing."}]},"timestamp":"%s"}\n' "$now" >> "$tx" ;;
    limit) printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 8:20pm (Asia/Tokyo)"}]},"timestamp":"%s"}\n' "$now" >> "$tx" ;;
  esac
done
sleep 30
SH
  } > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# _parked <tank> -> a transcript for <tank> holding one OLD genuine limit (the
# one that parked the session); prints its path.
_parked() {
  local proj="$CLIKAE_HOME/profiles/claude/$1/projects/p"
  mkdir -p "$proj"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · resets 8:20pm (Asia/Tokyo)"}]},"timestamp":"2026-09-16T13:37:00.000Z"}' > "$proj/s.jsonl"
  printf '%s' "$proj/s.jsonl"
}

_sess() { printf 'cksit-%s-%s' "$$" "${BATS_TEST_NUMBER:-0}"; }
_tankname() { printf 'ckt%s%s' "$$" "${BATS_TEST_NUMBER:-0}"; }

teardown() {
  tmux kill-session -t "$(_sess)" 2>/dev/null || true
  tmux kill-session -t "=$(_sess)-o" 2>/dev/null || true
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
  local tx; tx="$(_parked "$tank")"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_responder "$tx" "$out" turn)"
  sleep 1
  wake_sit "$(_sess)" "$(date +%s)" claude "$tank" >/dev/null
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ -f "$log" ] || { echo "no trace at $log"; false; }
  grep -q $'\tattached\t' "$log" || { cat "$log"; false; }
  grep -q $'\ttyped\t' "$log" || { cat "$log"; false; }
  grep -q $'\tconfirmed\t' "$log" || { cat "$log"; false; }
  # …and the thing a person actually runs surfaces the LAST one: what the
  # nudge caused, not merely that it was typed.
  run "$CLIKAE_BIN" wake
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-$tank"* ]] || { echo "$output"; false; }
  [[ "$output" == *"confirmed"* ]] || { echo "$output"; false; }
}

# --- #161: did the nudge land? ------------------------------------------------
#
# `send-keys` succeeding used to be the whole verdict: a "go" Claude refused, or
# one a modal swallowed, was logged `typed` and the waiter went home. These drive
# the real loop against a real pane whose "engine" answers each line by writing
# to the tank's real transcript, read through the real limit scanner.

@test "verify: a nudge answered by a new turn is CONFIRMED, and typed once" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  local tx; tx="$(_parked "$tank")"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_responder "$tx" "$out" turn)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ "$(tail -n 1 "$log" | cut -f3)" = "confirmed" ] || { cat "$log"; false; }
  ! grep -q $'\trefused\t' "$log" || { cat "$log"; false; }
  [ "$(grep -c . "$out")" -eq 1 ] || { cat "$out"; false; }
}

@test "verify: a nudge answered by a fresh limit is REFUSED, retried, and the retries are bounded" {
  # WAKE_RETRY_MAX=2 here: two nudges, two refusals, then a visible give-up —
  # never a third "go", and never a loop.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  local tx; tx="$(_parked "$tank")"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_responder "$tx" "$out" limit)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"refused"* ]] || { echo "$output"; false; }
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ "$(grep -c $'\trefused\t' "$log")" -eq 2 ] || { cat "$log"; false; }
  [ "$(tail -n 1 "$log" | cut -f3)" = "gave-up" ] || { cat "$log"; false; }
  ! grep -q $'\tconfirmed\t' "$log" || { cat "$log"; false; }
  sleep 1
  [ "$(grep -c . "$out")" -eq 2 ] || { echo "typed $(grep -c . "$out") times"; false; }
}

@test "verify: a refusal is retried, and a retry that lands is CONFIRMED" {
  # The refused test above would also pass for a waiter that gave up without
  # ever retrying if the count were not checked; this one needs the retry to
  # actually type again and read the second answer.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  local tx; tx="$(_parked "$tank")"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_responder "$tx" "$out" limit turn)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ "$(grep -c $'\trefused\t' "$log")" -eq 1 ] || { cat "$log"; false; }
  [ "$(tail -n 1 "$log" | cut -f3)" = "confirmed" ] || { cat "$log"; false; }
  [ "$(grep -c . "$out")" -eq 2 ] || { cat "$out"; false; }
}

@test "verify: a nudge with no answer is NO-EFFECT — logged once, never typed again" {
  # The old limit that parked the session is still in the transcript; it must
  # not be read as a refusal of the nudge (it is older than the send).
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank; tank="$(_tankname)"
  local tx; tx="$(_parked "$tank")"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_responder "$tx" "$out" none)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no new turn"* ]] || { echo "$output"; false; }
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  [ "$(tail -n 1 "$log" | cut -f3)" = "no-effect" ] || { cat "$log"; false; }
  ! grep -q $'\trefused\t' "$log" || { cat "$log"; false; }
  sleep 1
  [ "$(grep -c . "$out")" -eq 1 ] || { echo "typed $(grep -c . "$out") times"; false; }
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

# ── the fuel readout's refresher (the half that had no owner) ───────────────
#
# The status row reads the usage cache and can never fetch (tmux_status_fuelv).
# Until this landed, the only writers were `clikae usage` and burn — so on a
# machine where somebody only sits in interactive sessions the file just aged:
# measured at nine days old, with the row showing the "no reading" glyph the
# whole time. The watcher is already in that session, already looping, and
# already dies with it, so it is where the refresh belongs.

@test "watch: the fuel cache is refreshed on its OWN cadence, not every loop" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # Compressed exactly like the rest of this file: the VALUE of
  # WAKE_USAGE_INTERVAL is asserted in wake.bats, the SHAPE here.
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_ALONE_INTERVAL=1
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_USAGE_INTERVAL=3
  limit_tank_dry() { return 1; }              # never dry: only the cadence runs
  local calls="$BATS_TEST_TMPDIR/usage-calls"
  # The stub stands in for the one writer of the cache. Shell functions do
  # cross a background `&` (same shell), which is how the watcher below sees it.
  usage_read() { printf '%s/%s\n' "$1" "$2" >> "$calls"; }
  tmux new-session -d -s "$(_sess)" -n claude 'sleep 30'
  sleep 1
  wake_watch claude "$(_tankname)" "$(_sess)" >/dev/null &
  local w=$!
  sleep 7
  { kill "$w"; wait "$w"; } 2>/dev/null || true

  [ -f "$calls" ] || { echo "the watcher never refreshed the reading at all"; false; }
  local n; n="$(grep -c . "$calls")"
  # ~7 passes of the loop at a 3s cadence: 2 refreshes. The bounds are what the
  # test is FOR — an implementation that refreshed every pass would land near 7
  # and is the failure this exists to catch (a vendor call per loop, forever).
  [ "$n" -ge 1 ] || { echo "no refresh in 7s at a 3s cadence"; false; }
  [ "$n" -le 3 ] || { echo "refreshed $n times in 7s — that is every loop, not the cadence"; false; }
  [ "$(head -1 "$calls")" = "claude/$(_tankname)" ] \
    || { echo "refreshed the wrong tank: $(head -1 "$calls")"; false; }
}

@test "watch: a refresh that fails does not end the watcher" {
  # The reason it is silent AND ignored: this runs in the window a person is
  # told to watch their countdown in. A vendor that is down, a token that
  # expired, no network on a train — none of them may take the waiter with
  # them, and none of them may print over the countdown either.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_ALONE_INTERVAL=1
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_USAGE_INTERVAL=1
  limit_tank_dry() { return 1; }
  local calls="$BATS_TEST_TMPDIR/usage-calls"
  usage_read() { printf 'call\n' >> "$calls"; echo "vendor said no" >&2; return 1; }
  tmux new-session -d -s "$(_sess)" -n claude 'sleep 30'
  sleep 1
  wake_watch claude "$(_tankname)" "$(_sess)" > "$BATS_TEST_TMPDIR/watch-out" 2>&1 &
  local w=$!
  sleep 5
  local alive=0; kill -0 "$w" 2>/dev/null && alive=1
  { kill "$w"; wait "$w"; } 2>/dev/null || true

  [ "$alive" -eq 1 ] || { echo "a failing refresh ended the watcher"; cat "$BATS_TEST_TMPDIR/watch-out"; false; }
  [ -f "$calls" ] || { echo "the refresh never ran, so this proved nothing"; false; }
  [ "$(grep -c . "$calls")" -ge 2 ] \
    || { echo "it stopped refreshing after the first failure"; false; }
  ! grep -q "vendor said no" "$BATS_TEST_TMPDIR/watch-out" \
    || { echo "the failure was printed over the countdown"; cat "$BATS_TEST_TMPDIR/watch-out"; false; }
}

@test "launch: a fresh session fires exactly ONE reading, so the row has a number" {
  # The watcher's first tick is WAKE_USAGE_INTERVAL away, and it only exists
  # when wake is on (it is OFF for the whole suite — see tests/helpers.bash), so
  # the one-shot at launch is what puts a number on the row seconds after the
  # first attach. Counted at the VENDOR CALL, not at the cache file: "exactly
  # one" is a claim about what a launch spends.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local tank; tank="$(_tankname)"
  clikae init claude "$tank"
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"stub-secret-wake-usage"}}' \
    > "$CLIKAE_HOME/profiles/claude/$tank/.credentials.json"
  export USAGE_CALLS="$TEST_HOME/usage-calls"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
cat >/dev/null                       # the real call pipes its headers in via -K -
echo '{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":10,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}'
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
  printf '#!/usr/bin/env bash\nsleep 3\n' > "$TEST_HOME/.testbin/claude"
  chmod +x "$TEST_HOME/.testbin/claude"

  _pty_run "$CLIKAE_BIN" claude "$tank" >/dev/null 2>&1 || true
  # The refresh is backgrounded on purpose (the launch path pays nothing), so
  # wait for it to land rather than assuming it beat the process out the door.
  local cache="$CLIKAE_HOME/state/usage/claude/$tank.json" i
  for ((i = 0; i < 20; i++)); do [ -f "$cache" ] && break; sleep 0.5; done
  tmux kill-session -t "clikae-claude-$tank" 2>/dev/null || true

  [ -f "$cache" ] || { echo "a launch left the row with nothing to draw"; false; }
  grep -q '"window_pct":25' "$cache" || { echo "not the reading the vendor gave: $(cat "$cache")"; false; }
  [ -f "$USAGE_CALLS" ] || { echo "no vendor call was made"; false; }
  [ "$(grep -c . "$USAGE_CALLS")" -eq 1 ] \
    || { echo "a launch spent $(grep -c . "$USAGE_CALLS") vendor calls, not one"; false; }
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

# --- #162: the evidence is the PARKED SESSION's, not the tank's ---------------
#
# A usage limit hits the account, but the question the waiter asks is narrower:
# "is THIS conversation still sitting on its limit". Every transcript on the
# tank used to answer it — a background subagent's reply, or another session
# working on the same tank, read as "the vendor resumed", and the session that
# was actually parked was never nudged. The id clikae stamped at launch
# (tmux_set_session_id) is what names the parked session's own jsonl.

_LIMIT_LINE='{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit · %s"}]},"timestamp":"%s"}\n'
_TURN_LINE='{"type":"assistant","message":{"model":"claude-opus","content":[{"type":"text","text":"Done."}]},"timestamp":"%s"}\n'

# _parked_sid <tank> <sid> <phrase> <limit-stamp> -> the parked session's own
# transcript, named by its id the way Claude Code names it; prints its path.
_parked_sid() {
  local proj="$CLIKAE_HOME/profiles/claude/$1/projects/p"
  mkdir -p "$proj"
  # shellcheck disable=SC2059  # the format IS the fixture
  printf "$_LIMIT_LINE" "$3" "$4" > "$proj/$2.jsonl"
  printf '%s' "$proj/$2.jsonl"
}

# _subagent_turn <tank> <sid> <stamp> -> a background subagent of that session
# answering at <stamp>, where Claude Code keeps it (<sid>/subagents/*.jsonl).
_subagent_turn() {
  local d="$CLIKAE_HOME/profiles/claude/$1/projects/p/$2/subagents"
  mkdir -p "$d"
  # shellcheck disable=SC2059
  printf "$_TURN_LINE" "$3" > "$d/agent-a1.jsonl"
}

@test "#162 sit: a subagent's reply after the parked session's limit is NOT 'the vendor resumed'" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  [ -z "${TMUX:-}" ] && [ -n "${TMUX_TMPDIR:-}" ] || { echo "not on the suite's own tmux server"; false; }
  _src_wake
  local tank sid; tank="$(_tankname)"; sid="11111111-1111-4111-8111-111111111111"
  _parked_sid "$tank" "$sid" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z" >/dev/null
  _subagent_turn "$tank" "$sid" "2026-09-16T13:40:00.000Z"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$sid"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"resumed on its own"* ]] || { echo "$output"; false; }
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "not nudged: $output"; false; }
}

@test "#162 sit: another session's turn on the same tank does not skip the parked one either" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank sid; tank="$(_tankname)"; sid="22222222-2222-4222-8222-222222222222"
  _parked_sid "$tank" "$sid" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z" >/dev/null
  # shellcheck disable=SC2059
  printf "$_TURN_LINE" "2026-09-16T15:00:00.000Z" \
    > "$CLIKAE_HOME/profiles/claude/$tank/projects/p/33333333-3333-4333-8333-333333333333.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$sid"
  # The other session is a live clikae launch, stamped with its own id — which
  # is what tells it apart from this pane after a /clear (#182 round 2: an
  # unstamped newer transcript is ambiguous and reads the whole tank).
  tmux new-session -d -s "$(_sess)-o" "sleep 10"
  tmux set-option -t "=$(_sess)-o:" @clikae_session_id "33333333-3333-4333-8333-333333333333"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" != *"resumed on its own"* ]] || { echo "$output"; false; }
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "not nudged: $output"; false; }
}

@test "#162 sit: the parked session's OWN continuation is still a skip (the scope's control)" {
  # Without this, a scope that read nothing at all would pass the two above.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank sid; tank="$(_tankname)"; sid="44444444-4444-4444-8444-444444444444"
  local tx; tx="$(_parked_sid "$tank" "$sid" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z")"
  # shellcheck disable=SC2059
  printf "$_TURN_LINE" "2026-09-16T15:00:40.000Z" >> "$tx"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$sid"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" == *"resumed on its own"* ]] || { echo "$output"; false; }
  [ ! -f "$out" ] || { echo "typed anyway: $(cat "$out")"; false; }
}

@test "#162 watch: a subagent's later success still leaves the main session parked, so the watcher hands over" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  local phrase; phrase="$(_phrase_minutes_ago 10)" || skip "no named zone on this host"
  local tank sid; tank="$(_tankname)"; sid="55555555-5555-4555-8555-555555555555"
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  _parked_sid "$tank" "$sid" "$phrase" "$now.000Z" >/dev/null
  _subagent_turn "$tank" "$sid" "$now.900Z"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 60"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$sid"
  sleep 1
  wake_watch claude "$tank" "$(_sess)" >/dev/null &
  local w=$! i
  for ((i = 0; i < 20; i++)); do [ -s "$out" ] && break; sleep 1; done
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ -s "$out" ] || { echo "nothing was typed within 20s: the watcher kept watching"; false; }
  [ "$(cat "$out")" = "go" ]
}

@test "#163 watch: the watcher's own post-reset usage reading does not swallow 'parked'" {
  # The watcher refreshes the usage cache every 300s (wake_usage_refresh). A
  # reading taken after the reset instant is fine evidence that the ACCOUNT has
  # fuel — and no evidence at all that this conversation moved. Read on the
  # watcher's path it made _limit_tank_dry_self answer "not dry" before the
  # hand-over (`reset passed · unverified`) could be seen.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  local phrase; phrase="$(_phrase_minutes_ago 10)" || skip "no named zone on this host"
  local tank sid; tank="$(_tankname)"; sid="66666666-6666-4666-8666-666666666666"
  _parked_sid "$tank" "$sid" "$phrase" "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')" >/dev/null
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"source":"vendor","window_pct":4,"weekly_pct":31,"cached_at":%s}\n' "$(date +%s)" \
    > "$CLIKAE_HOME/state/usage/claude/$tank.json"
  # The reading still counts where it was meant to: the board's question.
  ! _limit_tank_dry_self claude "$tank" >/dev/null || { echo "precondition: the reading should clear the tank"; false; }
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 60"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$sid"
  sleep 1
  wake_watch claude "$tank" "$(_sess)" >/dev/null &
  local w=$! i
  for ((i = 0; i < 20; i++)); do [ -s "$out" ] && break; sleep 1; done
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ -s "$out" ] || { echo "nothing was typed within 20s: the reading swallowed 'parked'"; false; }
  [ "$(cat "$out")" = "go" ]
}

@test "#162 verify: a subagent's turn after the nudge is not the nudge landing" {
  _src_wake
  local tank sid s; tank="$(_tankname)"; sid="77777777-7777-4777-8777-777777777777"
  s="$(_sess)"
  mkdir -p "$HOME/.clikae/state"
  printf '%s\n' "$sid" > "$HOME/.clikae/state/$s.session_id"
  _parked_sid "$tank" "$sid" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z" >/dev/null
  local sent; sent="$(( $(date +%s) - 5 ))"
  _subagent_turn "$tank" "$sid" "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
  run wake_turn_since claude "$tank" "$sent" "$s"
  [ "$status" -eq 1 ] || { echo "rc=$status out=$output"; false; }
}

# --- #163: what was on the screen, and a menu that would eat the nudge --------

@test "#163 trace: the screen at send time is written down before typing" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "printf 'banner-one\nbanner-two\n'; read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  # What the screen WAS, as a class and a hash — never its text (#182 round 2).
  grep $'\tscreen\t' "$log" | grep -q 'unknown · h:' || { cat "$log"; false; }
  ! grep -q 'banner' "$log" || { cat "$log"; false; }
  # Written BEFORE the keystroke: the screen line precedes `typed`.
  [ "$(grep -n $'\tscreen\t' "$log" | head -1 | cut -d: -f1)" -lt \
    "$(grep -n $'\ttyped\t' "$log" | head -1 | cut -d: -f1)" ] || { cat "$log"; false; }
  # A plain screen is not a menu: nothing but the nudge was typed.
  sleep 1
  [ "$(cat "$out")" = "go" ]
}

# _menu_pane <out> <closes:1|0> -> a pane that shows a numbered menu with a
# cursor, the shape Claude Code draws at a limit. With closes=1 an Escape
# dismisses it back to a prompt that takes a line; otherwise every key is
# recorded and the menu stays.
_menu_pane() {
  local f="$BATS_TEST_TMPDIR/menu.sh"
  {
    printf '#!/bin/bash\nout=%q; closes=%q\n' "$1" "$2"
    cat <<'SH'
printf ' What do you want to do?\n\n ❯ 1. Stop and wait for limit to reset\n   2. Switch to extra usage\n   3. Upgrade your plan\n'
while IFS= read -rsn1 k; do
  if [ "$closes" = 1 ] && [ "$k" = $'\e' ]; then
    clear; printf '> '
    IFS= read -r line; printf 'ESC+%s' "$line" > "$out"; sleep 30; exit 0
  fi
  printf 'KEY:%q\n' "$k" >> "$out"
done
SH
  } > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

@test "#163 modal: a menu on screen is dismissed with Escape BEFORE the nudge is typed" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_menu_pane "$out" 1)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "ESC+go" ] || { echo "pane got: $(cat "$out" 2>/dev/null) / $output"; false; }
  grep -q $'\tmodal\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

@test "#163 modal: a menu that will not close is never typed into" {
  # Enter on a menu picks its highlighted option, and at a limit one of the
  # options can be "switch to extra usage". If Escape did not close it, the
  # only safe nudge is none.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_menu_pane "$out" 0)"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gave up"* ]] || { echo "$output"; false; }
  sleep 1
  # Escape reached the menu, and nothing else did — not "go", not Enter.
  [ -f "$out" ] || { echo "not even Escape reached the pane"; false; }
  [ -z "$(grep -v -F "KEY:\$'\\E'" "$out")" ] || { echo "typed into the menu: $(cat "$out")"; false; }
  grep -q 'menu' "$CLIKAE_HOME/state/wake/claude-$tank.log"
}

@test "#163 modal: the menu shape is a cursor on a numbered option plus another option" {
  _src_wake
  wake_screen_menu $' What now?\n ❯ 1. Stop and wait\n   2. Switch to extra usage' || false
  wake_screen_menu $'  > 1. Yes\n    2. No' || false
  wake_screen_menu $'│ ❯ 1. Yes │\n│   2. No  │' || false
  # A numbered list in the conversation, with no cursor on it, is not a menu.
  ! wake_screen_menu $' 1. first step\n 2. second step\n\n❯ ' || false
  # The bare prompt is not a menu.
  ! wake_screen_menu $'────\n❯ \n────' || false
  # One option is not a choice.
  ! wake_screen_menu $' ❯ 1. Continue' || false
}

# --- round 2 of #182: the trace keeps no screen text; the scope follows the
# pane past /clear; a menu counts only when the screen ENDS in it -------------

_mode() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }

# _mins_ago <file> <minutes> -> backdate a file's mtime (GNU or BSD date).
_mins_ago() {
  local t
  t="$(date -d "-$2 min" '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-"$2"M '+%Y%m%d%H%M.%S')"
  touch -t "$t" "$1"
}

_SECRET='sk-ant-api03-Zq9SECRETtokenXyZ'
_CUSTOMER='Customer Alice Wong owes 4200'

@test "#182r2 privacy: no pane text reaches any file under CLIKAE_HOME, and the trace is private" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  umask 022
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed" f="$BATS_TEST_TMPDIR/pane.sh"
  # An older trace from a binary that wrote it world-readable is tightened too.
  mkdir -p "$CLIKAE_HOME/state/wake"; chmod 755 "$CLIKAE_HOME/state/wake"
  : > "$CLIKAE_HOME/state/wake/claude-$tank.log"; chmod 644 "$CLIKAE_HOME/state/wake/claude-$tank.log"
  {
    printf '#!/bin/bash\nout=%q; secret=%q; cust=%q\n' "$out" "$_SECRET" "$_CUSTOMER"
    cat <<'SH'
printf 'export ANTHROPIC_API_KEY=%s\n%s\n\n ❯ 1. %s\n   2. %s\n' "$secret" "$cust" "$cust" "$secret"
while IFS= read -rsn1 k; do
  if [ "$k" = $'\e' ]; then
    clear; printf '%s\n%s\n> ' "$secret" "$cust"
    IFS= read -r line; printf 'ESC+%s' "$line" > "$out"; sleep 30; exit 0
  fi
done
SH
  } > "$f"; chmod +x "$f"
  tmux new-session -d -s "$(_sess)" "$f"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "ESC+go" ] || { echo "pane got: $(cat "$out" 2>/dev/null) / $output"; false; }
  local log="$CLIKAE_HOME/state/wake/claude-$tank.log"
  grep -q $'\tmodal\t' "$log" && grep -q $'\tscreen\t' "$log" || { cat "$log"; false; }
  ! grep -rqF "$_SECRET" "$CLIKAE_HOME" || { grep -rF "$_SECRET" "$CLIKAE_HOME"; false; }
  ! grep -rqF "Alice Wong" "$CLIKAE_HOME" || { grep -rF "Alice Wong" "$CLIKAE_HOME"; false; }
  ! grep -rqF "sk-ant" "$CLIKAE_HOME" || { grep -rF "sk-ant" "$CLIKAE_HOME"; false; }
  [ "$(_mode "$CLIKAE_HOME/state/wake")" = 700 ] || { echo "dir mode $(_mode "$CLIKAE_HOME/state/wake")"; false; }
  [ "$(_mode "$log")" = 600 ] || { echo "log mode $(_mode "$log")"; false; }
}

@test "#182r2 privacy: a brand-new trace is created 0600 in a 0700 dir under umask 022" {
  _src_wake
  umask 022
  wake_trace claude t s1 "screen" "prompt · h:1"
  [ "$(_mode "$CLIKAE_HOME/state/wake")" = 700 ] || { echo "dir mode $(_mode "$CLIKAE_HOME/state/wake")"; false; }
  [ "$(_mode "$CLIKAE_HOME/state/wake/claude-t.log")" = 600 ] || { echo "log mode $(_mode "$CLIKAE_HOME/state/wake/claude-t.log")"; false; }
}

@test "#182r2 screen: the class names what the decision needs, never the text" {
  _src_wake
  local c
  c="$(wake_screen_class $' What now?\n ❯ 1. Stop and wait\n   2. Switch to extra usage\n   3. Upgrade')"
  [ "$c" = "menu(3 options, cursor on 1)" ] || { echo "got: $c"; false; }
  c="$(wake_screen_class $'❯ 1. First customer item\n  2. Second customer item\n\n> ')"
  [ "$c" = "prompt" ] || { echo "got: $c"; false; }
  c="$(wake_screen_class $' What now?\n\n ❯ 1. Stop and wait for limit to reset')"
  [ "$c" = "menu?(1 option visible, cursor on 1)" ] || { echo "got: $c"; false; }
  c="$(wake_screen_class $'You have hit your session limit · resets 8pm')"
  [ "$c" = "limit-text" ] || { echo "got: $c"; false; }
  c="$(wake_screen_class $'banner-one\nbanner-two')"
  [ "$c" = "unknown" ] || { echo "got: $c"; false; }
  # The hash is short and is not the text.
  c="$(wake_screen_hash "$_SECRET")"
  case "$c" in *sk-ant*|'') echo "got: $c"; false ;; esac
  [[ "$c" =~ ^[0-9a-f]{8}$ ]] || { echo "not eight hex digits: $c"; false; }
  [ "$c" = "$(wake_screen_hash "$_SECRET")" ]
  [ "$c" != "$(wake_screen_hash "$_CUSTOMER")" ]
}

@test "#182r2 menu: numbered history ABOVE an ordinary prompt is not a menu (pure shape)" {
  _src_wake
  ! wake_screen_menu $'❯ 1. First customer item\n  2. Second customer item\n\n> ' || false
  ! wake_screen_menu $'│ ❯ 1. First │\n│   2. Second │\n╭────╮\n│ >  │\n╰────╯\n  ? for shortcuts' || false
  # A real menu still is, with a footer under it.
  wake_screen_menu $' ❯ 1. Stop\n   2. Switch\n\n Enter to confirm · Esc to cancel' || false
}

@test "#182r2 menu: numbered history above a prompt gets NO Escape, and the nudge is typed" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "printf '❯ 1. First customer item\n  2. Second customer item\n\n> '; IFS= read -r line; printf '%q' \"\$line\" > '$out'; sleep 10"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "pane got: $(cat "$out" 2>/dev/null) / $output"; false; }
  ! grep -q $'\tmodal\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
  grep $'\tscreen\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'prompt' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

@test "#182r2 menu: a clipped picker (only the cursor row visible) gets neither Escape nor the nudge" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed" f="$BATS_TEST_TMPDIR/clipped.sh"
  {
    printf '#!/bin/bash\nout=%q\n' "$out"
    cat <<'SH'
printf ' What do you want to do?\n\n ❯ 1. Stop and wait for limit to reset'
while IFS= read -rsn1 k; do printf 'KEY:%q\n' "$k" >> "$out"; done
SH
  } > "$f"; chmod +x "$f"
  tmux new-session -d -s "$(_sess)" "$f"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  sleep 1
  [ ! -f "$out" ] || { echo "keys reached the picker: $(cat "$out")"; false; }
  grep $'\tmodal\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'no Escape' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

# _two_convs <tank> <A> <B> <B-first-stamp> -> A: the launch-stamped transcript,
# last written 10 minutes ago with its limit at 13:37; B: written now, its first
# record at <B-first-stamp>. Both in the same project dir, as /clear leaves them.
_two_convs() {
  local proj="$CLIKAE_HOME/profiles/claude/$1/projects/p"
  mkdir -p "$proj"
  # shellcheck disable=SC2059
  printf "$_LIMIT_LINE" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z" > "$proj/$2.jsonl"
  _mins_ago "$proj/$2.jsonl" 10
  # shellcheck disable=SC2059
  printf "$_TURN_LINE" "$4" > "$proj/$3.jsonl"
}

# _holding <file> -> a pane-command prefix that starts a child of the pane's
# shell holding <file> open, the way an engine process holds a transcript.
_holding() { printf '( exec 3<%q; exec sleep 30 ) & ' "$1"; }

@test "#182r2 scope: after /clear the pane's conversation is the NEW transcript, never the launch stamp" {
  # #182 round 3: "after /clear" is proven by the pane's OWN process tree
  # holding B open. The same files with B held by a process OUTSIDE the pane
  # are the negative ownership control: ambiguous, whole tank.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b proj; tank="$(_tankname)"
  a="aaaaaaaa-1111-4111-8111-111111111111"; b="bbbbbbbb-2222-4222-8222-222222222222"
  _two_convs "$tank" "$a" "$b" "2026-09-16T15:00:00.000Z"
  proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  local _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY _WAKE_SCOPE_AMBIG_STAMP
  # Control: B is open, but in another (unstamped) terminal, not in this pane.
  tmux new-session -d -s "$(_sess)" "sleep 30"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  tmux new-session -d -s "$(_sess)-o" "$(_holding "$proj/$b.jsonl")sleep 30"
  sleep 1
  _wake_scopev claude "$tank" "$(_sess)"
  [ -z "$_LIMIT_PARKED_FILES" ] || { echo "another terminal's open file moved this pane: $_LIMIT_PARKED_FILES"; false; }
  tmux kill-session -t "=$(_sess)-o"; tmux kill-session -t "=$(_sess)"
  # The pane's own engine has B open: that is the pane's conversation now.
  tmux new-session -d -s "$(_sess)" "$(_holding "$proj/$b.jsonl")sleep 30"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  _wake_scopev claude "$tank" "$(_sess)"
  [[ "$_LIMIT_PARKED_FILES" != *"$a"* ]] || { echo "scoped to the stale stamp: $_LIMIT_PARKED_FILES"; false; }
  [[ "$_LIMIT_PARKED_FILES" == *"/$b.jsonl" ]] || { echo "files: $_LIMIT_PARKED_FILES"; false; }
  local l; l="$(wake_evidence_label claude "$tank" "$(_sess)")"
  [[ "$l" == "session bbbbbbbb"*"open"*"aaaaaaaa"* ]] || { echo "label: $l"; false; }
}

@test "#182r2 scope: a newer transcript that cannot be this pane's successor makes it AMBIGUOUS, whole tank, said so" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-3333-4333-8333-333333333333"; b="bbbbbbbb-4444-4444-8444-444444444444"
  # B's first record predates A's last: a /resume of an older conversation, or
  # another terminal on the same tank. Nothing in the files says which.
  _two_convs "$tank" "$a" "$b" "2026-09-16T12:00:00.000Z"
  tmux new-session -d -s "$(_sess)" "sleep 30"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  local _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY
  _wake_scopev claude "$tank" "$(_sess)"
  [ -z "$_LIMIT_PARKED_FILES" ] || { echo "files: $_LIMIT_PARKED_FILES"; false; }
  local l; l="$(wake_evidence_label claude "$tank" "$(_sess)")"
  [[ "$l" == "whole tank (ambiguous"* ]] || { echo "label: $l"; false; }
}

@test "#182r2 scope: a newer transcript another live session was launched on does not move this pane" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-5555-4555-8555-555555555555"; b="bbbbbbbb-6666-4666-8666-666666666666"
  _two_convs "$tank" "$a" "$b" "2026-09-16T15:00:00.000Z"
  tmux new-session -d -s "$(_sess)" "sleep 30"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  tmux new-session -d -s "$(_sess)-o" "sleep 30"
  tmux set-option -t "=$(_sess)-o:" @clikae_session_id "$b"
  local _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY
  _wake_scopev claude "$tank" "$(_sess)"
  [[ "$_LIMIT_PARKED_FILES" == *"/$a.jsonl" ]] || { echo "files: $_LIMIT_PARKED_FILES"; false; }
}

@test "#182r2 sit: a stale launch stamp's limit does not get 'go' typed into the conversation /clear started" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-7777-4777-8777-777777777777"; b="bbbbbbbb-8888-4888-8888-888888888888"
  _two_convs "$tank" "$a" "$b" "2026-09-16T15:00:00.000Z"
  local out="$BATS_TEST_TMPDIR/typed" proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  # The pane's engine holds B open: the /clear is proven, not inferred (r3).
  tmux new-session -d -s "$(_sess)" "$(_holding "$proj/$b.jsonl")read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" == *"nothing sent"* ]] || { echo "$output"; false; }
  [ ! -f "$out" ] || { echo "typed into B: $(cat "$out")"; false; }
  grep $'\tattached\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'session bbbbbbbb' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

@test "#182r2 watch: a limit left in the launch-stamped conversation does not hand over after /clear" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  # shellcheck disable=SC2034  # read by the wake loop sourced above
  WAKE_WATCH_INTERVAL=1
  local phrase; phrase="$(_phrase_minutes_ago 10)" || skip "no named zone on this host"
  local tank a b proj; tank="$(_tankname)"
  a="aaaaaaaa-9999-4999-8999-999999999999"; b="bbbbbbbb-0000-4000-8000-000000000000"
  proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"; mkdir -p "$proj"
  # shellcheck disable=SC2059
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  printf "$_LIMIT_LINE" "$phrase" "$now.000Z" > "$proj/$a.jsonl"
  _mins_ago "$proj/$a.jsonl" 1
  # shellcheck disable=SC2059
  printf "$_TURN_LINE" "$now.500Z" > "$proj/$b.jsonl"
  # #182 round 3: a distinguishing fixture. A's subagent refuses AFTER B's
  # turn, so the WHOLE TANK reads parked (newest line a limit), while B alone
  # does not. A watcher that fell back to the whole tank would hand over and
  # type; only one that read B leaves it alone. Not a candidate for the
  # pane's conversation either: subagents live a level down.
  mkdir -p "$proj/$a/subagents"
  # shellcheck disable=SC2059
  printf "$_LIMIT_LINE" "$phrase" "$now.900Z" > "$proj/$a/subagents/agent-a1.jsonl"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_holding "$proj/$b.jsonl")read -r line; printf '%s' \"\$line\" > '$out'; sleep 60"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  # Control: on the stamped transcript alone this limit IS parked, and so is
  # the whole tank.
  local _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY _WAKE_SCOPE_AMBIG_STAMP
  _LIMIT_PARKED_TANK="claude/$tank"; _LIMIT_PARKED_DIR="$CLIKAE_HOME/profiles/claude/$tank"
  _LIMIT_PARKED_FILES="$proj/$a.jsonl"
  _limit_tank_dry_self claude "$tank" >/dev/null || { echo "precondition: A should read parked"; false; }
  _LIMIT_PARKED_FILES=""
  _limit_tank_dry_self claude "$tank" >/dev/null || { echo "precondition: the whole tank should read parked"; false; }
  # The evidence the watcher will read: B, because the pane's engine has it open.
  _wake_scopev claude "$tank" "$(_sess)"
  [[ "$_LIMIT_PARKED_FILES" == *"/$b.jsonl" ]] || { echo "evidence: $_WAKE_SCOPE_WHY / files: $_LIMIT_PARKED_FILES"; false; }
  [[ "$_WAKE_SCOPE_WHY" == "session bbbbbbbb"* ]] || { echo "why: $_WAKE_SCOPE_WHY"; false; }
  unset _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY _WAKE_SCOPE_AMBIG_STAMP
  wake_watch claude "$tank" "$(_sess)" >/dev/null &
  local w=$! i
  for ((i = 0; i < 10; i++)); do [ -s "$out" ] && break; sleep 1; done
  { kill "$w"; wait "$w"; } 2>/dev/null || true
  [ ! -s "$out" ] || { echo "handed over and typed into B: $(cat "$out")"; false; }
}

# --- round 3 of #182: "moved on" needs evidence tied to the pane; a menu is
# the LAST thing on screen -----------------------------------------------------

_USER_LINE='{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"%s"}\n'

# _parked_and_later <tank> <A> <B> <B-line-format> -> A: the launch-stamped
# transcript, parked on a limit and quiet for 10 minutes; B: a conversation
# that BEGAN after A went quiet (the shape /clear leaves, and also the shape a
# bare `claude` in another terminal on the same tank leaves), written now.
_parked_and_later() {
  local proj="$CLIKAE_HOME/profiles/claude/$1/projects/p"
  mkdir -p "$proj"
  # shellcheck disable=SC2059
  printf "$_LIMIT_LINE" "resets 8:20pm (Asia/Tokyo)" "2026-09-16T13:37:00.000Z" > "$proj/$2.jsonl"
  _mins_ago "$proj/$2.jsonl" 10
  # shellcheck disable=SC2059
  printf "$4" "2026-09-16T15:00:00.000Z" > "$proj/$3.jsonl"
}

@test "#182r3 scope: a later unstamped conversation the pane does not hold is AMBIGUOUS, never its successor" {
  # The review's case, as scope: chronology (B began after A went quiet) is
  # not ownership. Nothing ties B to this pane, so the read is the whole tank
  # and the label says the pane is treated as possibly parked.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-a3a3-4a3a-8a3a-a3a3a3a3a3a3"; b="bbbbbbbb-b3b3-4b3b-8b3b-b3b3b3b3b3b3"
  _parked_and_later "$tank" "$a" "$b" "$_USER_LINE"
  tmux new-session -d -s "$(_sess)" "sleep 30"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  local _LIMIT_PARKED_TANK _LIMIT_PARKED_DIR _LIMIT_PARKED_FILES _WAKE_SCOPE_WHY _WAKE_SCOPE_AMBIG_STAMP
  _wake_scopev claude "$tank" "$(_sess)"
  [ -z "$_LIMIT_PARKED_FILES" ] || { echo "picked a conversation nothing ties to the pane: $_LIMIT_PARKED_FILES"; false; }
  [[ "$_WAKE_SCOPE_WHY" == "whole tank (ambiguous"*"possibly parked"* ]] || { echo "why: $_WAKE_SCOPE_WHY"; false; }
}

@test "#182r3 sit: A parked + a later unrelated B (a user line, no stamp): the waiter does NOT skip" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-a4a4-4a4a-8a4a-a4a4a4a4a4a4"; b="bbbbbbbb-b4b4-4b4b-8b4b-b4b4b4b4b4b4"
  _parked_and_later "$tank" "$a" "$b" "$_USER_LINE"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" != *"nothing sent"* ]] || { echo "skipped: $output"; false; }
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "not nudged: $output"; false; }
  grep $'\tpossibly-parked\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'ambiguous' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

@test "#182r3 sit: A parked + a later unrelated B with a SUCCESSFUL turn: not taken for 'resumed on its own'" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b; tank="$(_tankname)"
  a="aaaaaaaa-a5a5-4a5a-8a5a-a5a5a5a5a5a5"; b="bbbbbbbb-b5b5-4b5b-8b5b-b5b5b5b5b5b5"
  _parked_and_later "$tank" "$a" "$b" "$_TURN_LINE"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" != *"resumed on its own"* ]] || { echo "skipped as recovered: $output"; false; }
  [[ "$output" != *"nothing sent"* ]] || { echo "skipped: $output"; false; }
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "not nudged: $output"; false; }
}

@test "#182r3 sit: a proven move to a conversation that is ITSELF parked is still nudged" {
  # The pane's engine holds B open (a proven /clear), and B hit the limit too:
  # moving on is not a skip when where it moved to is parked.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  local tank a b proj fmt; tank="$(_tankname)"
  a="aaaaaaaa-a6a6-4a6a-8a6a-a6a6a6a6a6a6"; b="bbbbbbbb-b6b6-4b6b-8b6b-b6b6b6b6b6b6"
  # shellcheck disable=SC2059
  fmt="$(printf "$_LIMIT_LINE" "resets 8:20pm (Asia/Tokyo)" "%s")"
  _parked_and_later "$tank" "$a" "$b" "$fmt\n"
  proj="$CLIKAE_HOME/profiles/claude/$tank/projects/p"
  local out="$BATS_TEST_TMPDIR/typed"
  tmux new-session -d -s "$(_sess)" "$(_holding "$proj/$b.jsonl")read -r line; printf '%s' \"\$line\" > '$out'; sleep 10"
  tmux set-option -t "=$(_sess):" @clikae_session_id "$a"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [[ "$output" != *"nothing sent"* ]] || { echo "skipped: $output"; false; }
  sleep 1
  [ "$(cat "$out" 2>/dev/null)" = "go" ] || { echo "not nudged: $output"; false; }
  grep $'\tattached\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'session bbbbbbbb' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}

# The review's screen: numbered options with a cursor on them, and under them
# a limit banner and the automatic wait's countdown.
_OPTS_THEN_WAIT=$'❯ 1. First customer item\n  2. Second customer item\n\n You have hit your session limit · resets 3pm\n   Waiting for the limit to reset… 2h 13m'

@test "#182r3 menu: options followed by anything but the menu footer are NOT a menu (pure shape)" {
  _src_wake
  ! wake_screen_menu "$_OPTS_THEN_WAIT" || false
  local c; c="$(wake_screen_class "$_OPTS_THEN_WAIT")"
  [ "$c" = "menu?(2 options, cursor on 1, text below)" ] || { echo "got: $c"; false; }
  # The running-status hint is not a menu footer either.
  ! wake_screen_menu $' ❯ 1. Stop\n   2. Switch\n\n esc to interrupt' || false
  # Still a menu: only the vendor footer, blank rows, or the box under it.
  wake_screen_menu $' ❯ 1. Stop\n   2. Switch\n\n Enter to confirm · Esc to cancel' || false
  wake_screen_menu $'╭──────────╮\n│ ❯ 1. Yes │\n│   2. No  │\n╰──────────╯' || false
}

@test "#182r3 menu: a real menu is still seen under LC_ALL=C (byte-wise awk)" {
  # The box-border strip was a bracket of multibyte glyphs: in a byte-wise
  # awk it also ate the first byte of ❯, so no cursor was ever seen.
  _src_wake
  LC_ALL=C wake_screen_menu $' What now?\n ❯ 1. Stop and wait\n   2. Switch to extra usage' || false
  LC_ALL=C wake_screen_menu $'│ ❯ 1. Yes │\n│   2. No  │' || false
}

@test "#182r3 menu: options above a limit banner and countdown get NO Escape and nothing typed" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  _src_wake
  wake_tank_recovered() { return 1; }
  local tank; tank="$(_tankname)"
  local out="$BATS_TEST_TMPDIR/typed" f="$BATS_TEST_TMPDIR/wait.sh"
  {
    printf '#!/bin/bash\nout=%q; scr=%q\n' "$out" "$_OPTS_THEN_WAIT"
    cat <<'SH'
printf '%s' "$scr"
while IFS= read -rsn1 k; do printf 'KEY:%q\n' "$k" >> "$out"; done
SH
  } > "$f"; chmod +x "$f"
  tmux new-session -d -s "$(_sess)" "$f"
  sleep 1
  run wake_sit "$(_sess)" "$(date +%s)" claude "$tank"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  sleep 1
  [ ! -f "$out" ] || { echo "keys reached the waiting screen: $(cat "$out")"; false; }
  grep $'\tmodal\t' "$CLIKAE_HOME/state/wake/claude-$tank.log" | grep -q 'no Escape' \
    || { cat "$CLIKAE_HOME/state/wake/claude-$tank.log"; false; }
}
