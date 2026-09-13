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
echo '{"five_hour":{"utilization":65,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":92,"resets_at":"2099-01-07T00:00:00Z"}}'
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

@test "network failure is unknown; Codex status windows use ISO resets" {
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
  echo "$output" | jq -e '.source == "vendor" and .window_pct == 10 and .weekly_pct == 96 and .window_resets_at == "2100-01-01T00:00:00Z"'
}
