#!/usr/bin/env bats
# tests/bats/burn-dry-paused.bats — #178: a tank running dry under --no-reroute
# is a NORMAL, designed-for outcome (the quota window closes), not an anomaly.
# It must end in a terminal, resumable state a watcher can read, plus a note
# where a report-file waiter looks — never a quiet exit that a cockpit finds
# two hours later from `git status`.
#
#   · a burn that will NOT retry says `dry-paused` (ok:false → terminal for
#     every reader), with `reset` / `reset_at` so the watcher knows when to
#     come back; `clikae wait` returns IMMEDIATELY on it (rc 2, the dry class);
#   · --no-reroute waits out a parseable reset by default and re-fires the
#     same tank, and while it sleeps the status is the NON-terminal
#     `waiting-reset` — the tank stays busy and `wait` keeps waiting (#183
#     round 2); zero window = never retry, a past reset = one re-fire;
#   · the artifact path carries a one-line pause note when the engine wrote
#     nothing there (a waiter polling "does the report exist" wakes up),
#     created exclusively and removed only if still exactly as written.
#
# `sleep` is stubbed, as in burn-wait-for-reset.bats: the CHOICE is under test,
# not the clock. (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_burn() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/antigravity.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
}

_the_status_file() {
  local f
  f="$(ls "$CLIKAE_HOME"/logs/burn-*/status.json 2>/dev/null | head -n 1)"
  [ -n "$f" ] || return 1
  printf '%s' "$f"
}

# codex: dry on call 1 (reset phrase per $1), writes the artifact on call 2.
_stub_codex_dry_then_ok() {
  local phrase="$1"
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  local counter="$BATS_TEST_TMPDIR/codex_calls"
  cat > "$bin/codex" <<STUB
#!/usr/bin/env bash
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 1 ]; then
  echo "$phrase"
  exit 0
fi
if [ "\$1" = "run" ] && [ -n "\$2" ]; then : > "\$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# A limit burn recognises, with a reset it cannot turn into an instant.
NO_TIME="You've hit your usage limit. Try again at some undetermined time."
# A limit with a reset burn CAN parse (at most ~24h out on any real clock).
WITH_TIME="You've hit your usage limit. resets 11:59pm (UTC)"

_stub_sleep_noop() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep.log"
  cat > "$bin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SLEEP_LOG"
exit 0
STUB
  chmod +x "$bin/sleep"
  PATH="$bin:$PATH"; export PATH
}

@test "burn --no-reroute: dry with no waitable reset ends in state dry-paused, rc 2, with a pause note at the artifact path" {
  _stub_codex_dry_then_ok "$NO_TIME"
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --no-reroute --json -- run "$A"
  [ "$status" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "1" ]
  local f; f="$(_the_status_file)"
  [ -n "$f" ] || false
  [[ "$(cat "$f")" == *'"state":"dry-paused"'* ]] || false
  [[ "$(cat "$f")" == *'"ok":false'* ]] || false
  # The reason a --json consumer already keys on is unchanged.
  [[ "$output" == *'"reason":"tank ran dry and --no-reroute is set"'* ]] || false
  # The note: where a report-file waiter looks, saying what happened and
  # that nothing below it came from the engine.
  [ -f "$A" ]
  [[ "$(cat "$A")" == *"dry-paused"* ]] || false
  [[ "$(cat "$A")" == *"codex/T1"* ]] || false
}

@test "burn --no-reroute: the pause note never clobbers an artifact that is already there" {
  _stub_codex_dry_then_ok "$NO_TIME"
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  printf 'previous run output\n' > "$A"
  run clikae burn codex T1 --artifact "$A" --no-reroute -- run "$A"
  [ "$status" -eq 2 ]
  [ "$(cat "$A")" = "previous run output" ]
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"dry-paused"'* ]] || false
}

@test "wait: a dry-paused status is terminal — returns at once with rc 2 and prints it" {
  local run_id="burn-9178"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":false,"engine":"codex","tank":"T1","artifact":"/tmp/x.md","artifact_bytes":null,"reason":"tank ran dry and --no-reroute is set","reset":"resets 11:59pm (UTC)","rerouted_from":[],"elapsed_s":5,"run_id":"%s","state":"dry-paused","started_at":1,"updated_at":2,"pid":%s,"log":null,"reset_at":1900000000}\n' \
    "$run_id" "$$" > "$d/status.json"
  local t0=$SECONDS
  run clikae wait "$run_id" --timeout 15
  local elapsed=$((SECONDS - t0))
  [ "$status" -eq 2 ]
  [[ "$output" == *'"state":"dry-paused"'* ]] || false
  [ "$elapsed" -lt 10 ] || false
}

@test "_burn_dry_pause_window: 6h by default, CLIKAE_BURN_DRY_PAUSE_WAIT overrides, garbage falls back" {
  _src_burn
  unset CLIKAE_BURN_DRY_PAUSE_WAIT
  [ "$(_burn_dry_pause_window)" = "21600" ]
  [ "$(CLIKAE_BURN_DRY_PAUSE_WAIT=25h _burn_dry_pause_window)" = "90000" ]
  [ "$(CLIKAE_BURN_DRY_PAUSE_WAIT=0 _burn_dry_pause_window)" = "0" ]
  [ "$(CLIKAE_BURN_DRY_PAUSE_WAIT=junk _burn_dry_pause_window)" = "21600" ]
}

@test "burn --no-reroute: a parseable reset inside the window is waited out (stubbed sleep) and the SAME tank re-fires" {
  _stub_codex_dry_then_ok "$WITH_TIME"
  _stub_sleep_noop
  clikae init codex T1
  clikae init codex T2   # a reserve that --no-reroute must never touch
  local A="$BATS_TEST_TMPDIR/out.md"
  # 25h: "resets 11:59pm" is at most ~24h out on any real clock.
  CLIKAE_BURN_DRY_PAUSE_WAIT=25h run clikae burn codex T1 --artifact "$A" --no-reroute -- run "$A"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "2" ]
  [ -f "$SLEEP_LOG" ]
  [[ "$output" != *"codex/T2"* ]] || false
  [[ "$output" == *"waiting for its reset"* ]] || false
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"done"'* ]] || false
  [[ "$(cat "$f")" == *'"tank":"T1"'* ]] || false
}

@test "burn --no-reroute --wait-for-reset 0: an explicit zero window stops at dry-paused with reset_at set, instead of waiting" {
  _stub_codex_dry_then_ok "$WITH_TIME"
  _stub_sleep_noop
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --no-reroute --wait-for-reset 0 -- run "$A"
  [ "$status" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "1" ]
  # burn's own housekeeping may sleep a second here and there; the reset
  # wait would be hours. Nothing in that range.
  if [ -f "$SLEEP_LOG" ]; then
    ! awk '$1+0 > 60 { found=1 } END { exit !found }' "$SLEEP_LOG" || false
  fi
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"dry-paused"'* ]] || false
  [[ "$(cat "$f")" == *'"reset_at":'[0-9]* ]] || false
}

# --- round 2 (codex review of #183) ------------------------------------------

# codex: dries with $1 on every call, counting calls; never writes the
# artifact. From call 6 on it prints nothing at all (a plain task failure,
# rc 1), so a burn that spins on the dry ends instead of hanging the suite.
_stub_codex_always_dry() {
  local phrase="$1"
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  local counter="$BATS_TEST_TMPDIR/codex_calls"
  cat > "$bin/codex" <<STUB
#!/usr/bin/env bash
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
[ "\$n" -gt 5 ] && exit 0
echo "$phrase"
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

# A dated reset that is already years behind any real clock.
PAST_TIME="You've hit your usage limit. Upgrade to Pro or try again at Jan 1st, 2020 3:00 PM."

# sleep: short ones really sleep (queue polls, wait polls); a long one is the
# reset wait — it records that it started and blocks until the test drops
# $SLEEP_RELEASE (bounded at ~20s, so a failed test never leaves a sleeper).
_stub_sleep_blocking() {
  local bin="$BATS_TEST_TMPDIR/bin" real
  real="$(command -v sleep)"
  mkdir -p "$bin"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep.log"
  SLEEP_RELEASE="$BATS_TEST_TMPDIR/release"
  SLEEP_STARTED="$BATS_TEST_TMPDIR/sleeping"
  cat > "$bin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SLEEP_LOG"
case "\$1" in ''|*[!0-9]*) exec "$real" "\$@" ;; esac
if [ "\$1" -le 60 ]; then exec "$real" "\$@"; fi
: > "$SLEEP_STARTED"
i=0
while [ ! -e "$SLEEP_RELEASE" ] && [ "\$i" -lt 100 ]; do "$real" 0.2; i=\$((i + 1)); done
exit 0
STUB
  chmod +x "$bin/sleep"
  PATH="$bin:$PATH"; export PATH
}

_wait_for_file() {   # _wait_for_file <path> [tries of 0.1s]
  local i=0 n="${2:-100}"
  while [ ! -e "$1" ] && [ "$i" -lt "$n" ]; do command sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# Starts burn A on codex/T1 in the background, pinned, and returns once it is
# inside its reset sleep. Sets APID.
_start_sleeping_burn() {
  _stub_codex_dry_then_ok "$WITH_TIME"
  _stub_sleep_blocking
  clikae init codex T1
  A="$BATS_TEST_TMPDIR/a.md"
  CLIKAE_BURN_DRY_PAUSE_WAIT=25h clikae burn codex T1 --artifact "$A" --no-reroute -- run "$A" \
    > "$BATS_TEST_TMPDIR/a.log" 2>&1 3>&- &
  APID=$!
  if ! _wait_for_file "$SLEEP_STARTED" 150; then
    : > "$SLEEP_RELEASE"; wait "$APID"; cat "$BATS_TEST_TMPDIR/a.log"; return 1
  fi
}

@test "burn --no-reroute (P1): a burn sleeping to its reset KEEPS the tank — busy readers see it, a second burn is refused, --queue waits behind it" {
  _start_sleeping_burn
  local B="$BATS_TEST_TMPDIR/b.md" f st busy=1 active
  f="$(_the_status_file)"
  st="$(cat "$f")"
  _src_burn
  burn_tank_busy codex T1 && busy=0
  active="$(burn_status_active_tanks)"
  run clikae burn codex T1 --artifact "$B" --no-reroute -- run "$B"
  local refused_status="$status" refused_out="$output"
  CLIKAE_BURN_QUEUE_POLL_S=1 run clikae burn codex T1 --queue --queue-timeout 2 --artifact "$B" --no-reroute -- run "$B"
  local queued_status="$status" queued_out="$output"
  : > "$SLEEP_RELEASE"
  wait "$APID"; local arc=$?
  echo "status while sleeping: $st"
  echo "refused: $refused_out"
  echo "queued: $queued_out"
  [[ "$st" != *'"state":"dry-paused"'* ]] || false
  [[ "$st" == *'"ok":null'* ]] || false
  [ "$busy" -eq 0 ]
  [[ "$active" == *"codex/T1"* ]] || false
  [ "$refused_status" -ne 0 ]
  [[ "$refused_out" == *"already has a running burn"* ]] || false
  [ "$queued_status" -ne 0 ]
  [[ "$queued_out" == *"waiting behind run"* ]] || false
  [[ "$queued_out" == *"queue timeout"* ]] || false
  [ ! -e "$B" ]
  # …and A, released, re-fired the same tank and finished.
  [ "$arc" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "2" ]
  [[ "$(cat "$f")" == *'"state":"done"'* ]] || false
}

@test "burn --no-reroute (P2): --wait-for-reset 0 never retries, even when the reset is already in the past" {
  _stub_codex_always_dry "$PAST_TIME"
  _stub_sleep_noop
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --no-reroute --wait-for-reset 0 -- run "$A"
  [ "$status" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "1" ]
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"dry-paused"'* ]] || false
}

@test "burn --no-reroute (P2): a reset already in the past gets ONE re-fire under the default window, never a spin" {
  _stub_codex_always_dry "$PAST_TIME"
  _stub_sleep_noop
  clikae init codex T1
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" --no-reroute -- run "$A"
  [ "$status" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" = "2" ]
  local f; f="$(_the_status_file)"
  [[ "$(cat "$f")" == *'"state":"dry-paused"'* ]] || false
}

@test "_burn_dry_pause (P2): window 0 is refused before the reset is looked at; a past reset is bounded per run" {
  _src_burn
  _stub_sleep_noop
  limit_reset_epoch() { printf '1'; }
  local art="$BATS_TEST_TMPDIR/n.md"
  run _burn_dry_pause codex T1 "$art" "whenever" 0
  [ "$status" -eq 1 ]
  [ ! -f "$SLEEP_LOG" ]
  _BURN_DRY_PAUSE_PAST_REFIRES=0
  local first=0 second=0
  _burn_dry_pause codex T1 "$art" "whenever" 21600 || first=$?
  _burn_dry_pause codex T1 "$art" "whenever" 21600 || second=$?
  [ "$first" -eq 0 ]
  [ "$second" -eq 1 ]
}

@test "_burn_dry_pause (P2): text appended under the pause note while sleeping is never deleted" {
  _src_burn
  local art="$BATS_TEST_TMPDIR/n.md"
  limit_reset_epoch() { printf '%s' "$(( $(date +%s) + 30 ))"; }
  # The sleep is where a person (or another process) adds the real report.
  sleep() { printf 'REAL REPORT ADDED AFTER PAUSE\n' >> "$art"; }
  _burn_dry_pause codex T1 "$art" "soon" 21600
  [ -f "$art" ]
  [[ "$(cat "$art")" == *"REAL REPORT ADDED AFTER PAUSE"* ]] || false
}

@test "_burn_dry_pause (P2): a note this invocation did not write is never removed" {
  _src_burn
  local art="$BATS_TEST_TMPDIR/n.md"
  printf 'clikae burn: dry-paused — codex/T1 ran dry at earlier.\nREPORT FROM AN EARLIER RUN\n' > "$art"
  limit_reset_epoch() { printf '%s' "$(( $(date +%s) + 30 ))"; }
  sleep() { :; }
  _burn_dry_pause codex T1 "$art" "soon" 21600
  [ -f "$art" ]
  [[ "$(cat "$art")" == *"REPORT FROM AN EARLIER RUN"* ]] || false
}

@test "_burn_dry_pause (P2): its own unchanged note IS taken away before the re-fire" {
  _src_burn
  local art="$BATS_TEST_TMPDIR/n.md" seen="$BATS_TEST_TMPDIR/seen"
  limit_reset_epoch() { printf '%s' "$(( $(date +%s) + 30 ))"; }
  sleep() { cat "$art" > "$seen"; }
  _burn_dry_pause codex T1 "$art" "soon" 21600
  [[ "$(cat "$seen")" == "clikae burn: "* ]] || false
  [ ! -e "$art" ]
}

@test "_burn_pause_note (P2): created exclusively — never written through a path that appeared after the check" {
  _src_burn
  local art="$BATS_TEST_TMPDIR/n.md" target="$BATS_TEST_TMPDIR/elsewhere.md"
  # A dangling symlink: `[ -e ]` says nothing is there; a plain `>` follows it.
  ln -s "$target" "$art"
  _burn_pause_note codex T1 "$art" "soon"
  [ ! -e "$target" ]
}

@test "wait (P2): a burn sleeping to its reset is NOT terminal — wait keeps waiting; a second wait returns rc 0 on the eventual done" {
  _start_sleeping_burn
  local run_id
  run_id="$(basename "$(dirname "$(_the_status_file)")")"
  # First wait: the burn is mid-pause. It must NOT come back with a terminal row.
  run clikae wait "$run_id" --timeout 2
  local first_status="$status" first_out="$output"
  # --all likewise does not report it finished.
  run clikae wait "$run_id" --all --timeout 2
  local all_status="$status" all_out="$output"
  # Second wait: started while still sleeping, released underneath it.
  ( command sleep 1; : > "$SLEEP_RELEASE" ) 3>&- &
  run clikae wait "$run_id" --timeout 30
  local second_status="$status" second_out="$output"
  wait "$APID"
  echo "first=$first_status [$first_out] all=$all_status [$all_out] second=$second_status [$second_out]"
  [ "$first_status" -ne 0 ] && [ "$first_status" -ne 2 ]
  [[ "$first_out" != *'"state":"dry-paused"'* ]] || false
  [ "$all_status" -ne 0 ] && [ "$all_status" -ne 2 ]
  [ "$second_status" -eq 0 ]
  [[ "$second_out" == *'"state":"done"'* ]] || false
}

@test "wait (P2): a killed sleeper is seen as stale, not waited on forever" {
  local run_id="burn-9179" d="$CLIKAE_HOME/logs/burn-9179" dead
  mkdir -p "$d"
  ( exit 0 ) &
  dead=$!
  wait "$dead"
  printf '{"ok":null,"engine":"codex","tank":"T1","artifact":"/tmp/x.md","artifact_bytes":null,"reason":"tank ran dry and --no-reroute is set; waiting for its reset","reset":"resets 11:59pm (UTC)","rerouted_from":[],"elapsed_s":5,"run_id":"%s","state":"waiting-reset","started_at":1,"updated_at":2,"pid":%s,"log":null,"reset_at":1900000000}\n' \
    "$run_id" "$dead" > "$d/status.json"
  run clikae wait "$run_id" --timeout 10
  [ "$status" -eq 1 ]
  [[ "$output" == *'"state":"stale"'* ]] || false
}
