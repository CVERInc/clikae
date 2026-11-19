#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0

_seed_198() {
  clikae init codex sample >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/codex/sample/sessions"
  local now; now="$(date +%s)"
  # The weekly window is on its LAST day: reset distance cannot classify it.
  jq -c --argjson now "$now" --argjson age "${2:-0}" '
    .timestamp = ($now - $age | todateiso8601) |
    .payload.rate_limits.primary.resets_at = ($now + 3600) |
    if .payload.rate_limits.secondary != null then
      .payload.rate_limits.secondary.resets_at = ($now + 7200) else . end' \
    "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/$1.jsonl" \
    > "$CLIKAE_HOME/profiles/codex/sample/sessions/rollout-sample.jsonl"
}

_mutate_198() {
  local file="$CLIKAE_HOME/profiles/codex/sample/sessions/rollout-sample.jsonl"
  jq -c "$1" "$file" > "$TEST_HOME/changed.jsonl"
  mv "$TEST_HOME/changed.jsonl" "$file"
}

_check_198() {
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e "$1"
}

@test "198 point 1: weekly-only prolite and team remain weekly on the last day" {
  _seed_198 weekly-only
  for plan in prolite team; do
    _mutate_198 ".payload.rate_limits.plan_type = \"$plan\""
    run clikae usage codex sample --fresh --json
    _check_198 '.weekly_used_pct == 89 and .window_used_pct == null and .window_absent == true and (has("weekly_absent")|not)'
  done
}

@test "198 point 1: both windows follow duration even when swapped" {
  _seed_198 two-windows
  _mutate_198 '.payload.rate_limits |= (.primary as $p | .primary = .secondary | .secondary = $p)'
  run clikae usage codex sample --json
  _check_198 '.window_used_pct == 0 and .weekly_used_pct == 5 and (has("window_absent")|not) and (has("weekly_absent")|not)'
}

@test "198 point 1: missing duration is unreadable, never positional" {
  _seed_198 two-windows
  _mutate_198 'del(.payload.rate_limits.primary.window_minutes)'
  run clikae usage codex sample --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 5 and (has("window_absent")|not)'
}

@test "198 point 1: malformed percentage is unreadable, not an absent window" {
  _seed_198 two-windows
  _mutate_198 '.payload.rate_limits.primary.used_percent = "unreadable"'
  run clikae usage codex sample --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 5 and (has("window_absent")|not)'
}

_probe_198() {
  clikae init codex sample >/dev/null 2>&1
  export CLIKAE_CODEX_USAGE_PROBE=1
  cat > "$TEST_HOME/.testbin/codex" <<'STUB'
#!/usr/bin/env bash
[ "$1" = app-server ] || exit 64
while IFS= read -r line; do
  case "$line" in
    *'"account/rateLimits/read"'*) printf '%s\n' "$USAGE_198_PROBE"; break ;;
  esac
 done
STUB
  chmod +x "$TEST_HOME/.testbin/codex"
}

@test "198 point 1: app-server weekly-only plan explicitly lacks the short window" {
  _probe_198
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":89,"windowDurationMins":10080,"resetsAt":4102444800},"secondary":null}}}'
  run clikae usage codex sample --json
  _check_198 '.source == "vendor" and .weekly_used_pct == 89 and .window_used_pct == null and .window_absent == true'
}

@test "198 point 2: old transcript is stale in JSON and aged in the summary" {
  _seed_198 weekly-only 172800
  run --separate-stderr clikae usage codex sample
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2154
  [ "$stderr" = 'codex 11 2d ago' ]
  printf '%s\n' "${output#codex/sample }" | jq -e '.stale == true and .age_sec >= 172800'
  run clikae usage codex sample --json
  _check_198 '.stale == true and .age_sec >= 172800'
}

@test "198 point 2: fresh transcript is not stale and reset passage is explicit" {
  _seed_198 two-windows
  _mutate_198 '.payload.rate_limits.primary.resets_at = 1'
  run --separate-stderr clikae usage codex sample
  [ "$status" -eq 0 ]
  [ "$stderr" = 'codex 95' ]
  printf '%s\n' "${output#codex/sample }" | jq -e '(has("stale")|not) and .window_reset_passed == true'
}

@test "198 point 3: transcript used percentages equal 100 minus status text left" {
  _seed_198 two-windows
  run clikae usage codex sample --json
  [ "$status" -eq 0 ]
  local short weekly
  short="$(sed -n 's/^5h limit:.* \([0-9][0-9]*\)% left.*/\1/p' "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/status.txt")"
  weekly="$(sed -n 's/^Weekly limit:.* \([0-9][0-9]*\)% left.*/\1/p' "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/status.txt")"
  printf '%s\n' "$output" | jq -e --argjson s "$short" --argjson w "$weekly" \
    '.window_used_pct == (100-$s) and .weekly_used_pct == (100-$w) and .window_pct == .window_used_pct and .weekly_pct == .weekly_used_pct'
}

_public_198() {
  # shellcheck source=/dev/null
  source "$CLIKAE_TEST_ROOT/lib/core/usage.sh"
  printf '%s\n' "$2" | _usage_public "$1" sample 2000000000
}

@test "198 point 3: every engine public reading names used units and retains aliases" {
  for engine in claude codex antigravity grok; do
    run _public_198 "$engine" '{"source":"vendor","window_pct":12,"weekly_pct":34,"cached_at":2000000000}'
    _check_198 '.window_used_pct == 12 and .weekly_used_pct == 34 and .window_pct == .window_used_pct and .weekly_pct == .weekly_used_pct'
  done
}

@test "198 point 3: agy group percentages name used units and retain aliases" {
  run _public_198 antigravity '{"source":"quota-api","window_pct":12,"weekly_pct":34,"cached_at":2000000000,"groups":[{"name":"gemini","window_pct":12,"weekly_pct":34}]}'
  _check_198 '.groups[0] | .window_used_pct == 12 and .weekly_used_pct == 34 and .window_pct == .window_used_pct and .weekly_pct == .weekly_used_pct'
}

@test "198 point 3: last known percentages name used units and retain aliases" {
  run _public_198 codex '{"source":"unknown","window_pct":null,"weekly_pct":null,"cached_at":2000000000,"last_good":{"window_pct":12,"weekly_pct":34,"at":1999900000}}'
  _check_198 '.last_window_used_pct == 12 and .last_weekly_used_pct == 34 and .last_window_pct == .last_window_used_pct and .last_weekly_pct == .last_weekly_used_pct'
}

@test "198 point 3: model percentages name used units and retain aliases" {
  run _public_198 claude '{"source":"vendor","window_pct":12,"weekly_pct":34,"cached_at":2000000000,"models":[{"name":"example","pct":56}]}'
  _check_198 '.models[0] | .used_pct == 56 and .pct == .used_pct'
}

@test "198 point 3: dependency fallback still names used units" {
  # usage_read calls this directly when jq is unavailable.
  source "$CLIKAE_TEST_ROOT/lib/core/usage.sh"
  run usage_unknown
  _check_198 'has("window_used_pct") and has("weekly_used_pct") and .window_used_pct == null and .weekly_used_pct == null'
}

@test "198 point 1: invalid or missing duration never proves absence" {
  _seed_198 two-windows
  for duration in null 0 -1 '"300"'; do
    _mutate_198 ".payload.rate_limits.primary.window_minutes = $duration"
    run clikae usage codex sample --fresh --json
    _check_198 '.window_used_pct == null and .weekly_used_pct == 5 and (has("window_absent")|not)'
  done
  _mutate_198 'del(.payload.rate_limits.primary)'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 5 and (has("window_absent")|not)'
}

@test "198 point 1: app-server short-only plan lacks weekly but an unreadable side does not" {
  _probe_198
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":4102444800},"secondary":null}}}'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == 12 and .weekly_used_pct == null and .weekly_absent == true'
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":4102444800},"secondary":{"usedPercent":90}}}}'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == 12 and .weekly_used_pct == null and (has("weekly_absent")|not)'
}

@test "198 preservation: a rollout without readable percentages still tries app-server" {
  _probe_198
  mkdir -p "$CLIKAE_HOME/profiles/codex/sample/sessions"
  printf '%s\n' '{"timestamp":"2026-09-10T09:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":"unreadable","window_minutes":300},"secondary":null}}}' \
    > "$CLIKAE_HOME/profiles/codex/sample/sessions/rollout-sample.jsonl"
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":4102444800},"secondary":null}}}'
  run clikae usage codex sample --json
  _check_198 '.source == "vendor" and .window_used_pct == 12'
}

# Captured specimens (tests/fixtures/usage-codex/captured/): real token_count
# events, sanitized to the rate-limit fields only. The whole file is shifted so
# its last event is $2 seconds old; resets_at moves by the same amount, so
# every percentage, duration and event-to-reset distance is the captured one.
_seed_captured_198() {
  [ -d "$CLIKAE_HOME/profiles/codex/sample" ] || clikae init codex sample >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/profiles/codex/sample/sessions"
  local now; now="$(date +%s)"
  jq -sc --argjson now "$now" --argjson age "${2:-0}" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    ($now - $age - (.[-1].timestamp | epoch)) as $d |
    .[] | .timestamp = ((.timestamp | epoch) + $d | todateiso8601) |
    .payload.rate_limits |= (if . == null then . else
      (if .primary != null then .primary.resets_at += $d else . end) |
      (if .secondary != null then .secondary.resets_at += $d else . end) end)' \
    "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/captured/$1.jsonl" \
    > "$CLIKAE_HOME/profiles/codex/sample/sessions/rollout-sample.jsonl"
}

@test "198 captured: plus reports both windows by duration; a later empty premium event does not displace them" {
  _seed_captured_198 plus-two-windows
  run clikae usage codex sample --fresh --json
  _check_198 '.source == "transcript" and .window_used_pct == 100 and .weekly_used_pct == 53 and (has("window_absent")|not) and (has("weekly_absent")|not) and (has("stale")|not)'
}

@test "198 captured: weekly-only prolite and team stay weekly and lack the short window" {
  _seed_captured_198 prolite-weekly-only
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 33 and .window_absent == true and (has("weekly_absent")|not)'
  _seed_captured_198 team-weekly-only
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 100 and .window_absent == true and (has("weekly_absent")|not)'
}

@test "198 captured: an old capture is stale" {
  _seed_captured_198 team-weekly-only 172800
  run clikae usage codex sample --fresh --json
  _check_198 '.stale == true and .age_sec >= 172800 and .weekly_used_pct == 100'
}

@test "198 captured: usage JSON is percent used, the status renderer is percent left" {
  _seed_captured_198 plus-two-windows
  run clikae usage codex sample --fresh --json
  [ "$status" -eq 0 ]
  local short weekly note
  short="$(printf '%s\n' "$output" | jq -r '100 - .window_used_pct')"
  weekly="$(printf '%s\n' "$output" | jq -r '100 - .weekly_used_pct')"
  note="$(jq -r 'select(.payload.rate_limits.primary != null) | .payload.rate_limits |
    [.primary.used_percent, .primary.window_minutes, .secondary.used_percent, .secondary.window_minutes] | @tsv' \
    "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/captured/plus-two-windows.jsonl" | tail -n 1 |
    { IFS=$'\t' read -r pu pw su sw
      # shellcheck source=/dev/null
      . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
      # shellcheck source=/dev/null
      . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
      # shellcheck source=/dev/null
      . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
      limit_codex_status_note "$pu" "$pw" "" "$su" "$sw" "" "$(date +%s)"; })"
  [ "$note" = "5h ${short}% left · 7d ${weekly}% left" ]
}

# --- r1: one-off events, durations of other lengths, burn's unknown side ---
# A captured file with the rows its filter keeps, then seeded like the rest.
_seed_captured_rows_198() {
  local src="$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/captured" root="$TEST_HOME/fxroot"
  mkdir -p "$root/tests/fixtures/usage-codex/captured"
  jq -c "$2" "$src/$1.jsonl" > "$root/tests/fixtures/usage-codex/captured/r1.jsonl"
  CLIKAE_TEST_ROOT="$root" _seed_captured_198 r1 "${3:-0}"
}

@test "198 r1 captured: plus 7-day-only one-off keeps the 5-hour reading from the event before" {
  _seed_captured_198 plus-transient-weekly-only
  run --separate-stderr clikae usage codex sample --fresh --json
  # shellcheck disable=SC2154
  _check_198 '.window_used_pct == 14 and .weekly_used_pct == 9 and (has("window_absent")|not) and (has("weekly_absent")|not) and .age_sec >= 33'
  run --separate-stderr clikae usage codex sample
  [ "$status" -eq 0 ]
  [ "$stderr" = 'codex 91' ]
}

@test "198 r1 captured: plus 5-hour-only one-off keeps the weekly reading from the event before" {
  _seed_captured_198 plus-transient-window-only
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == 65 and .weekly_used_pct == 41 and (has("window_absent")|not) and (has("weekly_absent")|not)'
}

@test "198 r1 captured: a zero-length window never wins over the readings before it" {
  _seed_captured_198 plus-zero-duration
  run clikae usage codex sample --fresh --json
  _check_198 '.source == "transcript" and .window_used_pct == 19 and .weekly_used_pct == 93 and (has("window_absent")|not) and (has("weekly_absent")|not)'
}

@test "198 r1 captured: a plus one-off alone is never an absent window" {
  _seed_captured_rows_198 plus-transient-weekly-only 'select(.payload.rate_limits.secondary == null)'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 9 and (has("window_absent")|not)'
  _seed_captured_rows_198 plus-transient-window-only 'select(.payload.rate_limits.secondary == null)'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == 65 and .weekly_used_pct == null and (has("weekly_absent")|not)'
}

@test "198 r1: absence needs every recent event to agree, and a plan change starts over" {
  # Same shape on a plan that may lack the window, but an earlier event had it.
  _seed_captured_rows_198 plus-transient-weekly-only '.payload.rate_limits.plan_type = "team"'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == 14 and .weekly_used_pct == 9 and (has("window_absent")|not)'
  # A plus reading, then the plan became prolite: the plus 5-hour reading is not carried over.
  _seed_captured_rows_198 plus-transient-weekly-only 'if .payload.rate_limits.secondary == null then .payload.rate_limits.plan_type = "prolite" else . end'
  run clikae usage codex sample --fresh --json
  _check_198 '.window_used_pct == null and .weekly_used_pct == 9 and .window_absent == true'
}

@test "198 r1: a rollout whose only window is zero-length still asks app-server" {
  _probe_198
  _seed_captured_rows_198 plus-zero-duration 'select(.payload.rate_limits.secondary == null)'
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":4102444800},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":4102444800}}}}'
  run clikae usage codex sample --fresh --json
  _check_198 '.source == "vendor" and .window_used_pct == 12 and .weekly_used_pct == 34'
}

@test "198 r1: only 300 and 10080 minutes fill the slots; other lengths keep their own minutes" {
  _seed_198 weekly-only
  for minutes in 43200 1440 360; do
    _mutate_198 ".payload.rate_limits.plan_type = \"free\" | .payload.rate_limits.primary.window_minutes = $minutes"
    run clikae usage codex sample --fresh --json
    _check_198 ".window_used_pct == null and .weekly_used_pct == null and .other_windows[0].window_minutes == $minutes and .other_windows[0].used_pct == 89 and (.other_windows[0].resets_at|type) == \"string\" and (has(\"gap\")|not)"
  done
  run --separate-stderr clikae usage codex sample
  [ "$status" -eq 0 ]
  [ "$stderr" = 'codex 11' ]
}

@test "198 r1: app-server other lengths keep their own minutes" {
  _probe_198
  export USAGE_198_PROBE='{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":43200,"resetsAt":4102444800},"secondary":null}}}'
  run clikae usage codex sample --fresh --json
  _check_198 '.source == "vendor" and .window_used_pct == null and .weekly_used_pct == null and .other_windows == [{"window_minutes":43200,"used_pct":100,"resets_at":"2100-01-01T00:00:00Z"}]'
  source "$CLIKAE_TEST_ROOT/lib/core/usage.sh"
  run usage_board_fields codex sample
  [ "$(printf '%s' "$output" | cut -f1-3)" = "$(printf -- '-\t-\t100')" ]
  [ "$(printf '%s' "$output" | cut -f5)" = "30d:100" ]
}

_peek_198() {
  mkdir -p "$CLIKAE_HOME/state/usage/codex"
  printf '%s\n' "$2" | jq -c --argjson now "$(date +%s)" '. + {source:"transcript", cached_at:$now, scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/codex/$1.json"
}

@test "198 r1 burn: an unreadable side is not 0% used; known values rank as before" {
  # shellcheck source=/dev/null
  source "$CLIKAE_TEST_ROOT/lib/core/usage.sh"
  _peek_198 known '{"window_pct":12,"weekly_pct":34}'
  run usage_cache_peek codex known
  [ "$status" -eq 0 ]; [ "$output" = "$(printf '12\t34\t34')" ]
  _peek_198 absent '{"window_pct":null,"weekly_pct":34,"window_absent":true}'
  run usage_cache_peek codex absent
  [ "$status" -eq 0 ]; [ "$output" = "$(printf '0\t34\t34')" ]
  _peek_198 unread '{"window_pct":null,"weekly_pct":34}'
  run usage_cache_peek codex unread
  [ "$status" -ne 0 ]; [ -z "$output" ]
  _peek_198 unreadfull '{"window_pct":95,"weekly_pct":null}'
  run usage_cache_peek codex unreadfull
  [ "$status" -eq 0 ]; [ "$output" = "$(printf '95\t100\t100')" ]
  _peek_198 other '{"window_pct":null,"weekly_pct":null,"window_absent":true,"weekly_absent":true,"other_windows":[{"window_minutes":43200,"used_pct":100,"resets_at":"2100-01-01T00:00:00Z"}]}'
  run usage_cache_peek codex other
  [ "$status" -eq 0 ]; [ "$output" = "$(printf '0\t0\t100')" ]
}

@test "198 r1 burn: a tank with an unreadable window ranks after one with known headroom" {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=/dev/null
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/burn.sh"
  local tank
  for tank in aaunread bbknown; do
    clikae init codex "$tank" >/dev/null 2>&1
    mkdir -p "$CLIKAE_HOME/profiles/codex/$tank/sessions"
    jq -c --argjson now "$(date +%s)" '.timestamp = ($now | todateiso8601) |
      .payload.rate_limits.primary.resets_at = ($now + 3600) |
      .payload.rate_limits.secondary.resets_at = ($now + 7200) |
      .payload.rate_limits.primary.used_percent = 50 | .payload.rate_limits.secondary.used_percent = 50' \
      "$CLIKAE_TEST_ROOT/tests/fixtures/usage-codex/two-windows.jsonl" \
      > "$CLIKAE_HOME/profiles/codex/$tank/sessions/rollout-$tank.jsonl"
  done
  # aaunread: the 5-hour side has no duration (unreadable), weekly 5% used.
  # It used to rank as 0% / 5%, ahead of bbknown's real 50% / 50%.
  jq -c '.payload.rate_limits.secondary.used_percent = 5 | del(.payload.rate_limits.primary.window_minutes)' \
    "$CLIKAE_HOME/profiles/codex/aaunread/sessions/rollout-aaunread.jsonl" > "$TEST_HOME/r.jsonl"
  mv "$TEST_HOME/r.jsonl" "$CLIKAE_HOME/profiles/codex/aaunread/sessions/rollout-aaunread.jsonl"
  clikae usage codex aaunread --fresh --json >/dev/null 2>&1
  clikae usage codex bbknown --fresh --json >/dev/null 2>&1
  run _burn_next_same_engine codex '' '' '' 1
  [ "$status" -eq 0 ]
  [ "$output" = bbknown ]
}
