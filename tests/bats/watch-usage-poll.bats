#!/usr/bin/env bats
# tests/bats/watch-usage-poll.bats — #132, redirected: `clikae watch`'s tail
# loop polls the EXISTING usage_read on a TTL (lib/commands/watch.sh's
# _watch_usage_poll_*), instead of sending keystrokes into any pane. No pane
# is ever touched here; these are unit tests of the polling functions
# directly, plus a probe test proving the probe itself never moves the
# numbers it reads (DoD #3).

load '../helpers'

_boot() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/i18n.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/adapter_loader.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
  source "$CLIKAE_TEST_ROOT/lib/core/usage.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/watch_github.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/watch.sh"
}

# A curl stub that counts calls and answers with a fixed reading, or fails
# every call when $USAGE_FAIL=1 (429-shaped: exit 22, no status on stderr —
# same shape usage.bats' USAGE_FAIL uses, which adapter_usage's own fallback
# resolves to reason "network").
_usage_curl_stub() {
  export USAGE_CALLS="$TEST_HOME/calls"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
[ "${USAGE_FAIL:-0}" = 0 ] || { echo '{"error":"nope"}'; exit 22; }
echo '{"five_hour":{"utilization":40,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":55,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}'
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}

_seed_tank() {
  local tank="$1"
  clikae init claude "$tank" >/dev/null 2>&1
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"stub-tok-'"$tank"'"}}' \
    > "$CLIKAE_HOME/profiles/claude/$tank/.credentials.json"
}

# _quiet <cmd...> — bats-core installs a DEBUG trap per test (tracing.bash,
# for its own failure-line reporting) that is inherited into every subshell,
# including the one lib/adapters/claude.sh's adapter_usage forks around its
# vendor curl pipeline. On bash 3.2 (the macOS runner) that trap firing
# between the pipeline and adapter_usage's own `rc="${PIPESTATUS[1]}"`
# clobbers PIPESTATUS — measured as "exit: : numeric argument required" from
# claude.sh's `exit "$_claude_usage_curl_rc"`, which adapter_usage then reads
# as a failed call even though the stub curl succeeded, so a vendor-success
# read gets miscategorized as a failure (wrong backoff, wrong window_pct).
# `run` avoids this (bats-core's test_functions.bash disables the same trap
# for the duration of `run`), but forks a subshell of its own, which would
# lose this file's global side effects (_WATCH_USAGE_POLL_*). Disabling just
# the DEBUG trap for these direct, in-process calls is the narrow fix that
# keeps those writes in this shell. ubuntu-latest's bash 5 never hits this.
_quiet() {
  trap - DEBUG
  "$@"
}

@test "poll one: a fresh tank is polled (usage_read fires) and its backoff stays at base on success" {
  _boot
  _usage_curl_stub
  _seed_tank a
  local base; base="$(_watch_usage_poll_interval)"
  _quiet _watch_usage_poll_one claude a 1000
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  _watch_usage_poll_indexv claude a
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = "$base" ]
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = "$((1000 + base))" ]
}

@test "poll one: not due yet is a no-op (no second usage_read call)" {
  _boot
  _usage_curl_stub
  _seed_tank a
  _quiet _watch_usage_poll_one claude a 1000
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  # same tank, a moment later, still before its own next-poll time
  _quiet _watch_usage_poll_one claude a 1001
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
}

@test "poll one: repeated failures back off exponentially, capped, and reset on the next success" {
  _boot
  _usage_curl_stub
  _seed_tank a
  # usage_read has its own TTL cache (lib/core/usage.sh), keyed off REAL wall
  # time; a synthetic "now" fed only to the poll layer below would otherwise
  # get masked by that cache still being fresh in real seconds. TTL=0 isolates
  # what THIS test is about — the poll layer's own backoff gate — from
  # usage_read's separate, already-tested TTL behaviour (usage.bats).
  export CLIKAE_USAGE_TTL=0
  export USAGE_FAIL=1
  local base; base="$(_watch_usage_poll_interval)"
  local now=1000
  _quiet _watch_usage_poll_one claude a "$now"
  _watch_usage_poll_indexv claude a
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = "$((base * 2))" ]
  now=$(( now + base * 2 ))
  _quiet _watch_usage_poll_one claude a "$now"
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = "$((base * 4))" ]
  # not every tick re-hits the vendor: three ticks, two of them (still-idle
  # cadence check) between polls, only the two DUE calls above actually fired
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
  # a real reading resets the backoff straight back to base
  now=$(( now + base * 4 ))
  USAGE_FAIL=0 _quiet _watch_usage_poll_one claude a "$now"
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = "$base" ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 3 ]
}

@test "poll one: a token failure caches as unknown, never a stale-dressed-as-fresh number" {
  _boot
  _usage_curl_stub
  _seed_tank a
  export USAGE_FAIL=1
  _quiet _watch_usage_poll_one claude a 1000
  run usage_read claude a
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .window_pct == null and .weekly_pct == null'
}

@test "poll tick: walks every known tank once" {
  _boot
  _usage_curl_stub
  _seed_tank a
  _seed_tank b
  _quiet _watch_usage_poll_tick
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
}

# --- DoD #3: the probe (usage_read) never consumes what it measures --------

@test "usage_read: N back-to-back calls on one tank do not move weekly_pct/window_pct" {
  _boot
  _usage_curl_stub
  _seed_tank probe
  local i readings=()
  for i in 1 2 3 4 5; do
    readings+=("$(_quiet usage_read claude probe)")
  done
  # the vendor stub was only ever hit ONCE (usage_read's own cache absorbs the
  # rest) — this IS the mechanism that keeps a probe from moving its subject.
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  local w0 k0 w k
  w0="$(printf '%s' "${readings[0]}" | jq -r '.window_pct')"
  k0="$(printf '%s' "${readings[0]}" | jq -r '.weekly_pct')"
  for i in 1 2 3 4; do
    w="$(printf '%s' "${readings[$i]}" | jq -r '.window_pct')"
    k="$(printf '%s' "${readings[$i]}" | jq -r '.weekly_pct')"
    [ "$w" = "$w0" ]
    [ "$k" = "$k0" ]
  done
  [ "$w0" = "40" ]
  [ "$k0" = "55" ]
}
