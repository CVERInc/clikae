#!/usr/bin/env bats
load '../helpers'

usage_fixture() {
  clikae init claude work
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"stub-secret-usage72"}}' > "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  export USAGE_CALLS="$TEST_HOME/calls" USAGE_LOG="$TEST_HOME/curl.log"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >> "$USAGE_CALLS"
printf '%s\n' "$@" >> "$USAGE_LOG"
env >> "$USAGE_LOG"
config="$(cat)"
[[ "$config" == *'Authorization: Bearer stub-secret-usage72'* ]] || exit 2
[[ "$config" == *'anthropic-beta: oauth-2025-04-20'* ]] || exit 2
[ "${USAGE_FAIL:-0}" = 0 ] || { echo '{"error":"unauthorized"}'; exit 22; }
# P2-3 (round-1 review): the vendor's real shape is microseconds + a numeric
# UTC offset, never a bare "…Z" — the old fixture used "2099-01-01T00:00:00Z"
# and so never exercised the format the vendor actually sends.
echo '{"five_hour":{"utilization":65,"resets_at":"2099-01-01T00:00:00.189940+00:00"},"seven_day":{"utilization":92,"resets_at":"2099-01-07T00:00:00.189960+00:00"}}'
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}

@test "usage JSON, board percentages, TTL and fresh; secret stays off output argv environment and logs" {
  usage_fixture
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_HOME/output.log"
  echo "$output" | jq -e '.engine == "claude" and .tank == "work" and .window_pct == 65 and .weekly_pct == 92 and .source == "vendor"'
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" == *'window 65% · weekly 92%'* ]]
  printf '%s\n' "$output" >> "$TEST_HOME/output.log"
  run clikae usage --fresh --json
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
  ! grep -R 'stub-secret-usage72' "$USAGE_LOG" "$TEST_HOME/output.log" "$CLIKAE_HOME/state"
}

@test "401 becomes cached unknown and board survives" {
  usage_fixture
  export USAGE_FAIL=1
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .window_pct == null'
  [[ "$output" != *'stub-secret-usage72'* ]]
  run clikae
  [ "$status" -eq 0 ]
  [[ "$output" != *'stub-secret-usage72'* ]]
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
}

@test "expired TTL refreshes and malformed TTL uses default" {
  usage_fixture
  clikae usage --json
  CLIKAE_USAGE_TTL=bad clikae usage --json
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
  CLIKAE_USAGE_TTL=0 clikae usage --json
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 2 ]
}

@test "reserve ranks vendor headroom and skips solo tanks" {
  usage_fixture
  clikae init claude reserve
  clikae init claude private
  mkdir -p "$CLIKAE_HOME/state/usage/claude" "$CLIKAE_HOME/profiles/claude/private/clikae-meta"
  touch "$CLIKAE_HOME/profiles/claude/private/clikae-meta/solo"
  local t pct
  for t in work reserve private; do
    pct=10; [ "$t" != work ] || pct=95
    jq -cn --argjson pct "$pct" --argjson now "$(date +%s)" '{window_pct:$pct,weekly_pct:$pct,source:"vendor",cached_at:$now}' > "$CLIKAE_HOME/state/usage/claude/$t.json"
  done
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = reserve ]
}

@test "P2-9: a tank we have no reading for beats one known >=90% used" {
  usage_fixture
  clikae init claude aaa
  clikae init claude bbb
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  # aaa: no cache file at all (unknown). bbb: known, 99% used on both windows.
  jq -cn --argjson pct 99 --argjson now "$(date +%s)" \
    '{window_pct:$pct,weekly_pct:$pct,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/bbb.json"
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  # A tank known to be nearly exhausted must not outrank one we simply have
  # no data for — before this fix, unknown always lost to ANY reading.
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = aaa ]
}

@test "P2-6a: same-account tanks rank as one, using the worst shared reading" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  write_usage() { jq -cn --argjson pct "$2" --argjson now "$(date +%s)" \
    '{window_pct:$pct,weekly_pct:$pct,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/$1.json"; }

  # xxx and yyy share an account; xxx looks bad (95, >=90) and yyy looks
  # great (20) — but they are the SAME real quota. zzz is independent at 50.
  # Ranking must use the WORST shared reading (95, tier >=90), so the
  # genuinely independent 50% tank (zzz) wins, not yyy's falsely-good 20%.
  clikae init claude xxx; clikae init claude yyy; clikae init claude zzz
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/xxx/.claude.json"
  printf '{"emailAddress":"shared@acct"}\n' > "$CLIKAE_HOME/profiles/claude/yyy/.claude.json"
  write_usage xxx 95; write_usage yyy 20; write_usage zzz 50
  run _burn_next_same_engine claude '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = zzz ]
}

@test "P2-6b: a same-account sibling is never chosen as the next (consecutive) hop" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  write_usage() { jq -cn --argjson pct "$2" --argjson now "$(date +%s)" \
    '{window_pct:$pct,weekly_pct:$pct,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/$1.json"; }

  # ppp and qqq share an account; ppp is the tank the caller JUST tried
  # (passed in $tried). qqq looks great (5%) but sharing ppp's account means
  # hopping there gains nothing real — it must be skipped even though
  # dried_accts (confirmed-dry only) says nothing about it yet. rrr is the
  # only genuine option left.
  clikae init claude ppp; clikae init claude qqq; clikae init claude rrr
  printf '{"emailAddress":"hop@acct"}\n' > "$CLIKAE_HOME/profiles/claude/ppp/.claude.json"
  printf '{"emailAddress":"hop@acct"}\n' > "$CLIKAE_HOME/profiles/claude/qqq/.claude.json"
  write_usage ppp 30; write_usage qqq 5; write_usage rrr 60
  run _burn_next_same_engine claude ' claude/ppp' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = rrr ]
}

@test "cached vendor thresholds and expired reading preserve unverified fallback" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  __C_RED=R __C_YELLOW=Y __C_GREEN=G __C_RESET=''
  _home_is_dryv() { _DRY_RESET='reset passed · unverified'; return 1; }
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local pct expected
  for pct in 59 60 90; do
    case "$pct" in 59) expected=G● ;; 60) expected=Y◐ ;; 90) expected=R○ ;; esac
    jq -cn --argjson pct "$pct" --argjson now "$(date +%s)" '{window_pct:$pct,weekly_pct:0,source:"vendor",cached_at:$now}' > "$CLIKAE_HOME/state/usage/claude/work.json"
    _home_fuel_dotv '' claude work
    [ "$_FDOT" = "$expected" ]
  done
  CLIKAE_USAGE_TTL=0 _home_fuel_dotv '' claude work
  [ "$_FNOTE" = 'reset passed · unverified' ]
  [ "$_FDOT" = Y◐ ]
}

@test "Claude Keychain service uses the tank path; malformed credentials never invoke curl" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/adapters/claude.sh"
  local service
  service="$(_claude_keychain_service "$CLIKAE_HOME/profiles/claude/work")"
  cp "$CLIKAE_HOME/profiles/claude/work/.credentials.json" "$CLIKAE_TEST_KEYCHAIN/$service"
  rm "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  # Use a read-only stub with the same service assertion on every platform.
  cat > "$TEST_HOME/.testbin/security" <<STUB
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] || exit 1
[ "\$3" = '$service' ] || exit 1
cat '$CLIKAE_TEST_KEYCHAIN/$service'
STUB
  chmod +x "$TEST_HOME/.testbin/security"
  OSTYPE=darwin run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "vendor"'
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"bad\nheader"}}' > "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  run clikae usage claude work --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown"'
  [ "$(wc -l < "$USAGE_CALLS" | tr -d ' ')" = 1 ]
}

@test "P2-3: real vendor reset-instant shape expires correctly (negative control proves the old guard failed open)" {
  usage_fixture
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  source "$CLIKAE_LIB/core/usage.sh"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  local now=1789300000 past future
  past="2020-01-01T00:00:00.189940+00:00"     # real shape, well before $now
  future="2099-01-01T00:00:00.189940+00:00"   # real shape, well after $now

  # Negative control: the PRE-FIX regex (sub("\.[0-9]+Z$";"Z")) is a no-op on
  # this shape (no bare "Z" to match — it's "…mmmmmm+00:00"), so
  # fromdateiso8601 throws and `catch` used to report "still valid" no
  # matter what the timestamp actually said. Prove it fails open on a
  # timestamp from 2020 — if THIS assertion ever fails, the negative
  # control itself is broken, not the fix below.
  run jq -cn --arg ts "$past" --argjson now "$now" \
    '($ts | (try (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch ($now+1))) > $now'
  [ "$output" = true ]   # old regex: a 2020 timestamp reads as "not yet expired"

  # Fixed guard, same past timestamp, real shape, through usage_cached_fields:
  # an already-passed reset must NOT be trusted as a live reading. (jq 1.7's
  # `-e` reports a totally-empty stream as rc=4, not rc=1 — every caller in
  # this repo tests truthiness via `if usage_cached_fields ...; then`, which
  # treats any nonzero the same, so this asserts -ne 0 rather than a specific
  # code the jq version can change out from under.)
  jq -cn --arg ts "$past" --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:$ts,weekly_resets_at:null,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -ne 0 ]

  # Same fix, a real-shape FUTURE timestamp -> accepted.
  jq -cn --arg ts "$future" --argjson now "$now" \
    '{window_pct:50,weekly_pct:50,window_resets_at:$ts,weekly_resets_at:null,source:"vendor",cached_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/work.json"
  run usage_cached_fields claude work "$now"
  [ "$status" -eq 0 ]
}

@test "network failure is unknown; Codex status windows are honestly source:transcript" {
  usage_fixture
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 7\n' > "$TEST_HOME/.testbin/curl"
  run clikae usage claude work --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown"'
  clikae init codex work
  mkdir -p "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10"
  printf '%s\n' '{"timestamp":"2026-09-10T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":96,"window_minutes":10080,"resets_at":4103049600}}}}' > "$CLIKAE_HOME/profiles/codex/work/sessions/2026/09/10/rollout-usage.jsonl"
  run clikae usage codex work --json
  [ "$status" -eq 0 ]
  # P2-4 (round-1 review): no `codex` process ever runs for this — it's read
  # straight from the rollout transcript above, so source is honestly
  # "transcript", never "vendor" (#72's own acceptance criteria named
  # "transcript" as a real value; nothing in the repo ever produced it
  # before this fix).
  echo "$output" | jq -e '.source == "transcript" and .window_pct == 10 and .weekly_pct == 96 and .window_resets_at == "2100-01-01T00:00:00Z"'
  # cached_at is the rollout event's OWN timestamp (2026-09-10T09:00:00Z),
  # not "now" — a week-old-in-test-time reading must not read as freshly
  # polled. epoch("2026-09-10T09:00:00Z") = 1789030800.
  jq -e '.cached_at == 1789030800' "$CLIKAE_HOME/state/usage/codex/work.json"
}
