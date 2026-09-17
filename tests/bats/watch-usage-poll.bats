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
#
# #136: $USAGE_HTTP makes it answer with a real HTTP status (written to
# stderr, exit 22 — what curl 8.5 measurably does under `--fail -w
# '%{stderr}%{http_code}'`), and $USAGE_RETRY_AFTER adds that one header to
# the `-D` dump, CRLF-terminated, as the vendor would. Same shape as
# usage.bats' own fixture stub; kept in both files because each one's tests
# read a different layer.
_usage_curl_stub() {
  export USAGE_CALLS="$TEST_HOME/calls"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
config="$(cat)"
if [ -n "${USAGE_HTTP:-}" ]; then
  _hdr=""; _prev=""
  for _a in "$@"; do [ "$_prev" = "-D" ] && _hdr="$_a"; _prev="$_a"; done
  if [ -n "$_hdr" ] && [ "$_hdr" != /dev/null ]; then
    { printf 'HTTP/2 %s\r\n' "$USAGE_HTTP"
      [ -z "${USAGE_RETRY_AFTER:-}" ] || printf 'retry-after: %s\r\n' "$USAGE_RETRY_AFTER"
      printf '\r\n'; } > "$_hdr"
  fi
  printf '%s' "$USAGE_HTTP" >&2; exit 22
fi
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

# --- #136: the poll loop stops treating every failure as one thing ----------
#
# CLIKAE_USAGE_TTL=0 everywhere below for the same reason the backoff test
# above gives: usage_read's own cache is keyed off REAL wall time, and these
# tests feed a SYNTHETIC "now" to the poll layer only. Zero isolates the poll
# layer's scheduling — what these tests are about — from that separate,
# already-tested TTL.
_poll136_env() {
  export CLIKAE_USAGE_TTL=0
  export CLIKAE_WATCH_USAGE_INTERVAL=10
  export CLIKAE_WATCH_USAGE_MAX_BACKOFF=1800
}
# _poll136_creds <tank> [refresh] — overwrite a seeded tank's credentials,
# optionally with a refresh token (which is what decides whether a 401 reads
# `expired-token` or `no-credentials` — #107).
_poll136_creds() {
  jq -cn --arg rt "${2:-}" '{claudeAiOauth:({accessToken:"stub-tok"}
    + (if $rt == "" then {} else {refreshToken:$rt} end))}' \
    > "$CLIKAE_HOME/profiles/claude/$1/.credentials.json"
}

@test "#136: a 429 with Retry-After schedules THAT tank at now+retry_after, not a doubling" {
  _boot; _usage_curl_stub; _seed_tank a; _poll136_env
  export USAGE_HTTP=429 USAGE_RETRY_AFTER=45
  _quiet _watch_usage_poll_one claude a 1000
  _watch_usage_poll_indexv claude a
  [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = rate-limited ] \
    || { echo "state: ${_WATCH_USAGE_POLL_STATE[$_WUPI]}"; false; }
  # 45, the vendor's own number — NOT base*2 (20), which is what the
  # pre-#136 loop would have produced for this same failure.
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1045 ] \
    || { echo "next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 1045)"; false; }
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 45 ]
  # A second 429 does not compound it: the hint replaces the ramp, it does
  # not ride on top of one.
  _quiet _watch_usage_poll_one claude a 1045
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1090 ] \
    || { echo "next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 1090)"; false; }
  # And a success afterwards puts the tank straight back on the base cadence.
  unset USAGE_HTTP USAGE_RETRY_AFTER
  _quiet _watch_usage_poll_one claude a 1090
  [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = ok ]
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 10 ]
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1100 ]
}

@test "#136: an unusable Retry-After falls back to the doubling backoff" {
  _boot; _usage_curl_stub; _poll136_env
  export USAGE_HTTP=429
  # A fresh tank per case, so each one starts from the same base and the
  # arrays never carry a previous case's ramp into the next.
  local i=0 bad
  for bad in '' -5 abc 999999999 'Wed, 21 Oct 2026 07:28:00 GMT'; do
    i=$(( i + 1 ))
    _seed_tank "t$i"
    USAGE_RETRY_AFTER="$bad" _quiet _watch_usage_poll_one claude "t$i" 1000
    _watch_usage_poll_indexv claude "t$i"
    [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = rate-limited ] \
      || { echo "[$bad] state: ${_WATCH_USAGE_POLL_STATE[$_WUPI]}"; false; }
    # base*2 = 20, the existing backoff — never the garbage value itself.
    [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1020 ] \
      || { echo "[$bad] next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 1020)"; false; }
    [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 20 ]
  done
}

@test "#136: Retry-After is clamped to [base, max] — never faster than the cache, never past the ceiling" {
  _boot; _usage_curl_stub; _poll136_env
  export USAGE_HTTP=429
  # Below the base: a poll sooner than the base would only re-read
  # usage_read's own cached rate-limited reading and learn nothing.
  _seed_tank low
  USAGE_RETRY_AFTER=1 _quiet _watch_usage_poll_one claude low 1000
  _watch_usage_poll_indexv claude low
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1010 ] \
    || { echo "low next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 1010)"; false; }
  # Above the ceiling: the existing CLIKAE_WATCH_USAGE_MAX_BACKOFF wins.
  _seed_tank high
  USAGE_RETRY_AFTER=86400 _quiet _watch_usage_poll_one claude high 1000
  _watch_usage_poll_indexv claude high
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 2800 ] \
    || { echo "high next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 2800)"; false; }
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 1800 ]
}

@test "#136: an auth failure goes straight to the max interval and is marked — no doubling ramp" {
  _boot; _usage_curl_stub; _poll136_env
  # (a) 401 with no refresh token -> no-credentials.
  _seed_tank nologin; _poll136_creds nologin
  export USAGE_HTTP=401
  _quiet _watch_usage_poll_one claude nologin 1000
  _watch_usage_poll_indexv claude nologin
  [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = auth ] \
    || { echo "state: ${_WATCH_USAGE_POLL_STATE[$_WUPI]}"; false; }
  # 1800 on the FIRST failure, not base*2 = 20: waiting longer will not make
  # a missing login appear, so there is no ramp worth climbing.
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 2800 ] \
    || { echo "next: ${_WATCH_USAGE_POLL_NEXT[$_WUPI]} (wanted 2800)"; false; }
  # Still max on the second: it parks there, it does not compound past it.
  _quiet _watch_usage_poll_one claude nologin 2800
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 1800 ]
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 4600 ]
  # (b) 403 WITH a refresh token -> expired-token. #107 keeps these two words
  # apart (different remedies); the poll loop treats both as the auth class.
  _seed_tank lapsed; _poll136_creds lapsed rt-stub-value
  USAGE_HTTP=403 _quiet _watch_usage_poll_one claude lapsed 1000
  _watch_usage_poll_indexv claude lapsed
  [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = auth ] \
    || { echo "403 state: ${_WATCH_USAGE_POLL_STATE[$_WUPI]}"; false; }
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 2800 ]
}

@test "#136: a 500 is still the transient class — it doubles, exactly as before" {
  _boot; _usage_curl_stub; _seed_tank srv; _poll136_env
  export USAGE_HTTP=500
  _quiet _watch_usage_poll_one claude srv 1000
  _watch_usage_poll_indexv claude srv
  [ "${_WATCH_USAGE_POLL_STATE[$_WUPI]}" = transient ] \
    || { echo "state: ${_WATCH_USAGE_POLL_STATE[$_WUPI]}"; false; }
  [ "${_WATCH_USAGE_POLL_NEXT[$_WUPI]}" = 1020 ]
  _quiet _watch_usage_poll_one claude srv 1020
  [ "${_WATCH_USAGE_POLL_BACKOFF[$_WUPI]}" = 40 ]
}
