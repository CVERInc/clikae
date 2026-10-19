#!/usr/bin/env bats
# tests/bats/burn-dry-paused.bats — #178: a tank running dry under --no-reroute
# is a NORMAL, designed-for outcome (the quota window closes), not an anomaly.
# It must end in a terminal, resumable state a watcher can read, plus a note
# where a report-file waiter looks — never a quiet exit that a cockpit finds
# two hours later from `git status`.
#
#   · status.json says `dry-paused` (ok:false → terminal for every reader),
#     with `reset` / `reset_at` so the watcher knows when to come back;
#   · the artifact path carries a one-line pause note when the engine wrote
#     nothing there (a waiter polling "does the report exist" wakes up);
#   · `clikae wait` returns IMMEDIATELY on it (rc 2, the dry class);
#   · --no-reroute waits out a parseable reset by default and re-fires the
#     same tank (the existing --wait-for-reset mechanism), instead of stopping.
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
  [[ "$output" == *"dry-paused"* ]] || false
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
