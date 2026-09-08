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
