#!/usr/bin/env bats
# tests/bats/burn-wait-for-reset.bats — #38: `--wait-for-reset <dur>` — when a
# tank runs dry and its reset falls within <dur>, sleep to it and re-fire the
# SAME tank instead of rerouting or Stopping.
#
# `sleep` itself is stubbed to a no-op that logs its argument, so the suite
# never actually waits real wall-clock time — the CHOICE (wait vs. move on)
# and the RETRY are what's under test, not the clock. limit_reset_epoch's own
# minute-granularity means the exact `--wait-for-reset` window used here is
# generous enough to swallow that on any real clock (see the comment at each
# test). (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_burn() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/json.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/burn_status.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/antigravity.sh"
  . "$CLIKAE_TEST_ROOT/lib/commands/burn.sh"
}

@test "_burn_parse_duration: bare seconds, and m/h/d suffixes" {
  _src_burn
  [ "$(_burn_parse_duration 45)" = "45" ]
  [ "$(_burn_parse_duration 90s)" = "90" ]
  [ "$(_burn_parse_duration 30m)" = "1800" ]
  [ "$(_burn_parse_duration 2h)" = "7200" ]
  [ "$(_burn_parse_duration 1d)" = "86400" ]
}

@test "_burn_parse_duration: refuses garbage rather than guessing" {
  _src_burn
  run _burn_parse_duration "abc"
  [ "$status" -ne 0 ]
  run _burn_parse_duration "30x"
  [ "$status" -ne 0 ]
  run _burn_parse_duration ""
  [ "$status" -ne 0 ]
  run _burn_parse_duration "12m3"
  [ "$status" -ne 0 ]
}

# --- end-to-end: dry, within the window, waits and retries the SAME tank ----

_stub_codex_reset_then_ok() {
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
  echo "You've hit your usage limit. resets 11:59pm (UTC)"
  exit 0
fi
if [ "\$1" = "run" ] && [ -n "\$2" ]; then : > "\$2"; fi
exit 0
STUB
  chmod +x "$bin/codex"
  PATH="$bin:$PATH"; export PATH
}

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

@test "--wait-for-reset: dry within the window waits (stubbed) and retries the SAME tank" {
  _stub_codex_reset_then_ok
  _stub_sleep_noop
  clikae init codex T1
  clikae init codex T2   # a reserve tank that must NEVER be touched
  local A="$BATS_TEST_TMPDIR/out.md"
  # 90000s (25h) safely covers the worst case of "resets 11:59pm" (next
  # occurrence is at most ~24h away) on any real clock this runs on.
  run clikae burn codex T1 --artifact "$A" --wait-for-reset 90000s -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ] || false
  [[ "$output" == *"within --wait-for-reset"* ]] || false
  [[ "$output" == *"codex/T1"* ]] || false
  [[ "$output" != *"Rerouting (dry)"* ]] || false   # never moved to T2
  [ "$(cat "$BATS_TEST_TMPDIR/codex_calls")" -eq 2 ] || false   # dry once, then retried
  [ -s "$SLEEP_LOG" ] || false                                  # it actually waited
}

@test "--wait-for-reset: a reset OUTSIDE the window still reroutes normally" {
  _stub_codex_reset_then_ok
  _stub_sleep_noop
  clikae init codex T1
  clikae init codex T2
  local A="$BATS_TEST_TMPDIR/out.md"
  # A 1-second window essentially never covers "next occurrence of 11:59pm" —
  # this exercises the "outside the window" branch, which must behave exactly
  # like burn always has: reroute to the next reserve tank.
  run clikae burn codex T1 --artifact "$A" --wait-for-reset 1s -- run "$A"
  [ "$status" -eq 0 ]
  [ -f "$A" ] || false
  [[ "$output" == *"ran dry"* ]] || false
  [[ "$output" == *"codex/T2"* ]] || false
}

@test "--wait-for-reset: omitted, behaviour is unchanged (still reroutes on dry)" {
  _stub_codex_reset_then_ok
  clikae init codex T1
  clikae init codex T2
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex/T2"* ]] || false
}

@test "--wait-for-reset: a bad duration is refused up front" {
  clikae init codex T1
  run clikae burn codex T1 --artifact "$BATS_TEST_TMPDIR/out.md" --wait-for-reset banana -- run x
  [ "$status" -ne 0 ]
  [[ "$output" == *"--wait-for-reset"* ]] || false
}

# --- P1-2 (2026-09-09 round-1 review): the sleep used to be preceded by a
# TERMINAL `dry` write — #41's `wait` and #40's `burn_tank_busy` both read a
# tank sleeping to a near reset as "this run is over" for the whole window.
# _burn_wait_for_reset is unit-tested directly (as _burn_parse_duration
# already is above) with a fully controlled clock/sleep/reset-resolver, so
# the mutation the round-1 review used to PROVE the gap (`sleep 1` in place
# of `sleep "$_wfr_remain"`) has something that actually turns red.

@test "_burn_wait_for_reset: sleeps the COMPUTED remaining seconds and shows a NON-terminal status meanwhile" {
  _src_burn
  run_dir="$BATS_TEST_TMPDIR/run-a"; mkdir -p "$run_dir"
  t0=$SECONDS; tried=""; burn_id="burn-a"; started_at=100

  date() { printf '1000\n'; }              # "now" is always 1000
  limit_reset_epoch() { printf '1300\n'; } # the reset always resolves to 1300 (300s out)
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-a.log"
  DURING_FILE="$BATS_TEST_TMPDIR/during-a.json"
  sleep() {
    printf '%s\n' "$1" >> "$SLEEP_LOG"
    cat "$run_dir/status.json" > "$DURING_FILE" 2>/dev/null || true
  }

  run _burn_wait_for_reset codex T1 /tmp/x.md "resets soon (UTC)" 86400
  [ "$status" -eq 0 ]
  # THE mutation kill: a hardcoded `sleep 1` would log "1" here, not "300".
  [ "$(head -n1 "$SLEEP_LOG")" = "300" ] || { echo "first sleep arg: $(cat "$SLEEP_LOG")"; false; }
  [[ "$(cat "$DURING_FILE")" == *'"state":"waiting-reset"'* ]] || false
  [[ "$(cat "$DURING_FILE")" == *'"ok":null'* ]] || false
  [[ "$(cat "$DURING_FILE")" == *'"reset_at":1300'* ]] || false
  [[ "$(cat "$DURING_FILE")" != *'"state":"dry"'* ]] || false
}

@test "_burn_wait_for_reset: re-checks on wake and waits once more if still short of the window" {
  _src_burn
  run_dir="$BATS_TEST_TMPDIR/run-c"; mkdir -p "$run_dir"
  t0=$SECONDS; tried=""; burn_id="burn-c"; started_at=100

  date() { printf '1000\n'; }   # the clock never advances (a no-op sleep, same as the E2E suite above)
  limit_reset_epoch() { printf '1300\n'; }
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-c.log"
  sleep() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }

  run _burn_wait_for_reset codex T1 /tmp/x.md "resets soon (UTC)" 86400
  [ "$status" -eq 0 ]
  # slept at least twice (the first wait, then the re-check's one bounded
  # extra wait) — both for the same still-computed remaining time, never a
  # busy/instant spin.
  [ "$(wc -l < "$SLEEP_LOG" | tr -d ' ')" -ge 2 ] || false
  [ "$(head -n1 "$SLEEP_LOG")" = "300" ] || false
}

@test "_burn_wait_for_reset: gives up once a moved reset would exceed the ORIGINAL window" {
  _src_burn
  run_dir="$BATS_TEST_TMPDIR/run-b"; mkdir -p "$run_dir"
  t0=$SECONDS; tried=""; burn_id="burn-b"; started_at=100

  date() { printf '1000\n'; }
  # A counter in a FILE, not a variable: `limit_reset_epoch` is always called
  # through `$(...)`, which forks a subshell per call — a plain variable
  # increment there is thrown away the instant that subshell exits.
  LRE_CALLS="$BATS_TEST_TMPDIR/lre_calls-b"; printf '0' > "$LRE_CALLS"
  limit_reset_epoch() {
    local n; n=$(($(cat "$LRE_CALLS") + 1)); printf '%s' "$n" > "$LRE_CALLS"
    if [ "$n" -eq 1 ]; then printf '1200'; else printf '1500'; fi
  }
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-b.log"
  sleep() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }

  run _burn_wait_for_reset codex T1 /tmp/x.md "resets soon (UTC)" 200
  [ "$status" -ne 0 ]
  # never slept a SECOND time once the moved reset fell outside the window
  [ "$(wc -l < "$SLEEP_LOG" | tr -d ' ')" -eq 1 ] || false
}

@test "burn_tank_busy: a waiting-reset marker with a live pid counts as busy" {
  clikae init codex T1
  local run_id="burn-wfr-busy"
  local d="$CLIKAE_HOME/logs/$run_id"
  mkdir -p "$d"
  printf '{"ok":null,"engine":"codex","tank":"T1","artifact":null,"artifact_bytes":null,"reason":"waiting for reset","reset":"resets soon","rerouted_from":[],"elapsed_s":0,"run_id":"%s","state":"waiting-reset","started_at":1,"updated_at":1,"pid":%s,"log":null,"reset_at":9999999999}\n' \
    "$run_id" "$$" > "$d/status.json"
  local A="$BATS_TEST_TMPDIR/out.md"
  run clikae burn codex T1 --artifact "$A" -- run "$A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a running burn"* ]] || false
  [ ! -e "$A" ] || false
}
