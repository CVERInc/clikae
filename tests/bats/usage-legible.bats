#!/usr/bin/env bats
# #149: a usage cell never prints blank. No test here reaches a vendor: claude's
# curl and codex's `codex app-server` are stubs on PATH.
load '../helpers'
bats_require_minimum_version 1.5.0   # for `run --separate-stderr`

_claude_fixture() {
  clikae init claude work >/dev/null 2>&1
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"stub-secret-149","refreshToken":"rt-stub"}}' \
    > "$CLIKAE_HOME/profiles/claude/work/.credentials.json"
  cat > "$TEST_HOME/.testbin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [ -n "${USAGE_HTTP:-}" ]; then printf '%s' "$USAGE_HTTP" >&2; exit 22; fi
if [ "${USAGE_NETFAIL:-0}" = 1 ]; then printf '000' >&2; exit 6; fi
printf '200' >&2
echo '{"five_hour":{"utilization":65,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":92,"resets_at":"2099-01-07T00:00:00.000000+00:00"}}'
STUB
  chmod +x "$TEST_HOME/.testbin/curl"
}
# _age_cache <engine> <tank> <seconds> — the cached reading is that old.
_age_cache() {
  local f="$CLIKAE_HOME/state/usage/$1/$2.json" at
  at=$(( $(date +%s) - $3 ))
  jq -c --argjson at "$at" '.cached_at = $at | .scanned_at = $at' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
_board_env() {
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/i18n.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/adapter_loader.sh"
  source "$CLIKAE_LIB/core/dry_store.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/core/duration.sh"
  source "$CLIKAE_LIB/core/usage.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  __C_YELLOW=YELLOW; __C_DIM=DIM; __C_GREEN=GREEN; __C_RED=RED; __C_RESET=""
}
_agy_tank() {
  local d="$CLIKAE_HOME/profiles/antigravity/$1"
  mkdir -p "$d/antigravity-cli/log"
  printf 'antigravity\n' > "$d/.clikae-tank"
  [ -z "${2:-}" ] || { : > "$d/antigravity-cli/log/cli-1.log"; touch -t "$2" "$d/antigravity-cli/log/cli-1.log"; }
}

@test "#149 expired: the reading carries gap expired and the last good numbers with their age" {
  _claude_fixture
  run clikae usage claude work --fresh --json
  echo "$output" | jq -e '.weekly_pct == 92 and (has("gap") | not)' || { echo "got: $output"; false; }
  _age_cache claude work 18000
  USAGE_HTTP=401 run --separate-stderr clikae usage claude work --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "expired" and .gap == "expired" and .weekly_pct == null
    and .last_weekly_pct == 92 and .last_window_pct == 65 and .last_age_sec >= 18000
    and .last_age_sec < 18100' || { echo "got: $output"; false; }
  # A second failure keeps the SAME last good reading, not the failed one.
  USAGE_NETFAIL=1 run clikae usage claude work --fresh --json
  echo "$output" | jq -e '.gap == "no-signal" and .reason == "network" and .last_weekly_pct == 92' \
    || { echo "second got: $output"; false; }
  [[ "$output" != *stub-secret* ]] || false
}

@test "#149 no-signal: a probe that answered nothing usable, with no reading ever, says null not blank" {
  _claude_fixture
  USAGE_NETFAIL=1 run clikae usage claude work --fresh --json
  echo "$output" | jq -e '.gap == "no-signal" and .last_weekly_pct == null and .last_at == null
    and has("last_age_sec")' || { echo "got: $output"; false; }
}

@test "#149 no-probe: codex with no rollout reading and its probe off, plus the dry marker's time" {
  clikae init codex marlin >/dev/null 2>&1
  mkdir -p "$CLIKAE_HOME/dry/codex"
  printf '1790000000\treset passed · unverified\n' > "$CLIKAE_HOME/dry/codex/marlin"
  run clikae usage codex marlin --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "unknown" and .gap == "no-probe" and .dry_marked_at == 1790000000' \
    || { echo "got: $output"; false; }
}

@test "#149 codex probe: app-server account/rateLimits/read is read into the right slot" {
  clikae init codex marlin >/dev/null 2>&1
  export CODEX_PROBE_LOG="$TEST_HOME/codex-probe.log"
  cat > "$TEST_HOME/.testbin/codex" <<'STUB'
#!/usr/bin/env bash
[ "$1" = app-server ] || exit 64
printf 'CODEX_HOME=%s\n' "$CODEX_HOME" >> "$CODEX_PROBE_LOG"
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) echo '{"id":1,"result":{}}' ;;
    *'"account/rateLimits/read"'*)
      echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":43200,"resetsAt":4070908800},"secondary":null}}}' ;;
  esac
done
STUB
  chmod +x "$TEST_HOME/.testbin/codex"
  CLIKAE_CODEX_USAGE_PROBE=1 run clikae usage codex marlin --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "vendor" and .weekly_pct == 100 and .window_pct == null
    and (has("gap") | not)' || { echo "got: $output"; false; }
  grep -q "CODEX_HOME=$CLIKAE_HOME/profiles/codex/marlin" "$CODEX_PROBE_LOG"
  # The board reads the one axis it has; the missing one is "-", never 0.
  source "$CLIKAE_LIB/core/usage.sh"
  run usage_board_fields codex marlin
  [ "$(printf '%s' "$output" | cut -f1)" = "-" ]
  [ "$(printf '%s' "$output" | cut -f2)" = "100" ]
}

@test "#149 codex probe off (the suite default): the stub is never run" {
  clikae init codex marlin >/dev/null 2>&1
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$TEST_HOME" > "$TEST_HOME/.testbin/codex"
  chmod +x "$TEST_HOME/.testbin/codex"
  run clikae usage codex marlin --fresh --json
  [ ! -e "$TEST_HOME/ran" ]
}

@test "#149 agy: a tank reads no-signal with when its own log was last written" {
  _agy_tank ray 202609201200
  run clikae usage agy --json
  [ "$status" -eq 0 ]
  local want
  want="$(stat -c %Y "$CLIKAE_HOME/profiles/antigravity/ray/antigravity-cli/log/cli-1.log" 2>/dev/null ||
          stat -f %m "$CLIKAE_HOME/profiles/antigravity/ray/antigravity-cli/log/cli-1.log")"
  echo "$output" | jq -e --argjson w "$want" '.engine == "antigravity" and .gap == "no-signal" and .last_used_at == $w' \
    || { echo "got: $output"; false; }
}

@test "#149 agy: the board row says no-signal and last used, never an empty green" {
  _agy_tank ray 202609201200
  _board_env
  local at now
  at="$(usage_agy_last_used ray)"; now=$(( at + 7200 ))
  _home_fuel_dotv_compute "" antigravity ray "$now"
  [ "$_FDOT" = "DIM·" ]
  [ "$_FNOTE" = "no-signal · last used 2h ago" ] || { echo "note: $_FNOTE"; false; }
  _agy_tank chromis
  _home_fuel_dotv_compute "" antigravity chromis "$now"
  [ "$_FNOTE" = "no-signal · never used" ]
}

@test "#149 board: an expired cell prints the last good weekly number, its age and the word expired" {
  _board_env
  local now; now="$(date +%s)"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"expired","reason":"expired-token","cached_at":%s,"scanned_at":%s,"last_good":{"window_pct":10,"weekly_pct":85,"at":%s}}\n' \
    "$now" "$now" "$(( now - 18000 ))" > "$CLIKAE_HOME/state/usage/claude/goby.json"
  _home_fuel_dotv_compute "" claude goby "$now"
  [ "$_FNOTE" = "weekly 85% · 5h ago · expired" ] || { echo "note: $_FNOTE"; false; }
  printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","cached_at":%s,"scanned_at":%s,"last_good":{"window_pct":null,"weekly_pct":40,"at":%s}}\n' \
    "$now" "$now" "$(( now - 3600 ))" > "$CLIKAE_HOME/state/usage/codex/marlin.json" 2>/dev/null ||
    { mkdir -p "$CLIKAE_HOME/state/usage/codex"; printf '{"window_pct":null,"weekly_pct":null,"window_resets_at":null,"weekly_resets_at":null,"source":"unknown","cached_at":%s,"scanned_at":%s,"last_good":{"window_pct":null,"weekly_pct":40,"at":%s}}\n' "$now" "$now" "$(( now - 3600 ))" > "$CLIKAE_HOME/state/usage/codex/marlin.json"; }
  _home_fuel_dotv_compute "" codex marlin "$now"
  [ "$_FNOTE" = "weekly 40% · 1h ago · no-probe" ] || { echo "codex note: $_FNOTE"; false; }
}

@test "#149 stale date: claude's comma form 'resets Sep 20, 11pm' resolves, so five days later it has passed" {
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  local anchor at
  anchor="$(_limit_at Asia/Taipei 2026-09-18 10:00)"
  run limit_reset_epoch 'resets Sep 20, 11pm (Asia/Taipei)' "$anchor"
  [ "$status" -eq 0 ]
  at="$(_limit_at Asia/Taipei 2026-09-20 23:00)"
  [ "$output" = "$at" ]
  # The "at" form it already knew is unchanged.
  run limit_reset_epoch 'resets Sep 20 at 11pm (Asia/Taipei)' "$anchor"
  [ "$output" = "$at" ]
}

@test "#149 stale date: the tuna row — an old comma-form limit plus a fresh 96% reading prints the number, not the date" {
  _board_env
  local now stamp
  now="$(date +%s)"
  stamp="$(TZ=UTC command date -u -r $(( now - 5 * 86400 )) +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null ||
           TZ=UTC command date -u -d "@$(( now - 5 * 86400 ))" +%Y-%m-%dT%H:%M:%S.000Z)"
  local phrase
  phrase="resets $(TZ=Asia/Taipei command date -r $(( now - 4 * 86400 )) '+%b %-d, %-I%p' 2>/dev/null ||
                   TZ=Asia/Taipei command date -d "@$(( now - 4 * 86400 ))" '+%b %-d, %-I%p') (Asia/Taipei)"
  phrase="${phrase/AM/am}"; phrase="${phrase/PM/pm}"
  clikae init claude tuna >/dev/null 2>&1
  # Globals, not locals: _limit_tank_dry_self declares its own `stamp`, and
  # bash's dynamic scope would hand this stub that empty local instead.
  T149_PHRASE="$phrase" T149_STAMP="$stamp"
  _limit_tank_dry_raw() { printf '%s\037%s' "$T149_PHRASE" "$T149_STAMP"; }
  run _limit_tank_dry_self claude tuna
  [ "$output" = "$LIMIT_RESET_UNVERIFIED" ] || { echo "phrase=$T149_PHRASE got: $output"; false; }
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  # A reading from BEFORE the reset instant proves nothing: still unverified.
  printf '{"window_pct":12,"weekly_pct":96,"window_resets_at":"2099-01-01T00:00:00Z","weekly_resets_at":"2099-01-07T00:00:00Z","source":"vendor","cached_at":%s,"scanned_at":%s}\n' \
    "$(( now - 5 * 86400 ))" "$now" > "$CLIKAE_HOME/state/usage/claude/tuna.json"
  run _limit_tank_dry_self claude tuna
  [ "$output" = "$LIMIT_RESET_UNVERIFIED" ] || { echo "pre-reset reading got: $output"; false; }
  # One taken after it is the vendor's word on the window since: not dry.
  printf '{"window_pct":12,"weekly_pct":96,"window_resets_at":"2099-01-01T00:00:00Z","weekly_resets_at":"2099-01-07T00:00:00Z","source":"vendor","cached_at":%s,"scanned_at":%s}\n' \
    "$now" "$now" > "$CLIKAE_HOME/state/usage/claude/tuna.json"
  local set
  set="$(printf 'claude\ttuna\t%s\n' "$CLIKAE_HOME/profiles/claude/tuna" | limit_dry_set --include-unverified)"
  [ -z "$set" ] || { echo "still in the dry set: $set"; false; }
  _home_fuel_dotv_compute "$set" claude tuna "$now"
  [ "$_FNOTE" = "window 12% · weekly 96%" ] || { echo "set=[$set] note: $_FNOTE"; false; }
}

_goby_cache() { # <weekly> <models-json-array-or-empty>
  local now; now="$(date +%s)"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  jq -cn --argjson k "$1" --argjson now "$now" --arg m "${2:-}" '
    {window_pct:1,weekly_pct:$k,window_resets_at:"2099-01-01T00:00:00Z",weekly_resets_at:"2099-01-07T00:00:00Z",source:"vendor"}
    + (if $m == "" then {} else {models:($m|fromjson)} end) + {cached_at:$now,scanned_at:$now}' \
    > "$CLIKAE_HOME/state/usage/claude/goby.json"
}

@test "#149 per-model: a vendor model row below the tank value, or no models[] at all, adds nothing" {
  _board_env
  _goby_cache 87 '[{"name":"Fable","pct":40,"resets_at":"2099-01-07T00:00:00Z"}]'
  _home_fuel_dotv_compute "" claude goby "$(date +%s)"
  [ "$_FNOTE" = "window 1% · weekly 87%" ] || { echo "below: $_FNOTE"; false; }
  _goby_cache 87 '[]'
  _home_fuel_dotv_compute "" claude goby "$(date +%s)"
  [ "$_FNOTE" = "window 1% · weekly 87%" ] || { echo "empty: $_FNOTE"; false; }
  _goby_cache 87 ''
  _home_fuel_dotv_compute "" claude goby "$(date +%s)"
  [ "$_FNOTE" = "window 1% · weekly 87%" ] || { echo "absent: $_FNOTE"; false; }
  # Any vendor name, not a known one; above the tank but under 100 is shown
  # without changing the dot.
  _goby_cache 20 '[{"name":"Other Model","pct":55,"resets_at":"2099-01-07T00:00:00Z"}]'
  _home_fuel_dotv_compute "" claude goby "$(date +%s)"
  [ "$_FNOTE" = "window 1% · weekly 20% · Other Model 55%" ] || { echo "other: $_FNOTE"; false; }
  [ "$_FDOT" = "GREEN●" ]
}

@test "#149 per-model: a spent model row rides in the board note and turns a green dot yellow" {
  _board_env
  local now; now="$(date +%s)"
  mkdir -p "$CLIKAE_HOME/state/usage/claude"
  printf '{"window_pct":1,"weekly_pct":87,"window_resets_at":"2099-01-01T00:00:00Z","weekly_resets_at":"2099-01-07T00:00:00Z","source":"vendor","models":[{"name":"Fable","pct":100,"resets_at":"2099-01-07T00:00:00Z"}],"cached_at":%s,"scanned_at":%s}\n' \
    "$now" "$now" > "$CLIKAE_HOME/state/usage/claude/goby.json"
  _home_fuel_dotv_compute "" claude goby "$now"
  [ "$_FNOTE" = "window 1% · weekly 87% · Fable 100%" ] || { echo "note: $_FNOTE"; false; }
  [ "$_FDOT" = "YELLOW◐" ]
}

@test "#149 summary: plain usage ends with one line per engine on stderr; --json has none" {
  _claude_fixture
  clikae init codex marlin >/dev/null 2>&1
  _agy_tank ray 202609201200
  _agy_tank anthias 202609181200
  run --separate-stderr clikae usage --fresh
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  local last
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
  last="$(printf '%s\n' "$stderr" | tail -n 1)"
  # Engines in listing order; one token each here.
  # agy: one "last used ... ago" around every tank's age, not the phrase per tank.
  [[ "$last" =~ ^agy\ last\ used\ [0-9]+d/[0-9]+d\ ago\ ·\ claude\ 92\ ·\ codex\ \?\?$ ]] || { echo "summary: $last"; false; }
  # stdout stays one line per tank.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 4 ]
  run --separate-stderr clikae usage --json
  [[ "$stderr" != *"codex ??"* ]] || false
  # A spent per-model row is named beside the tank's number.
  jq -c '. + {models:[{name:"Fable",pct:100,resets_at:"2099-01-07T00:00:00Z"}]} | .scanned_at = (now|floor)' \
    "$CLIKAE_HOME/state/usage/claude/work.json" > "$TEST_HOME/w.json"
  mv "$TEST_HOME/w.json" "$CLIKAE_HOME/state/usage/claude/work.json"
  run --separate-stderr clikae usage claude
  [ "$(printf '%s\n' "$stderr" | tail -n 1)" = "claude 92(Fable 100)" ] || { echo "stderr: $stderr"; false; }
  # A row at or below the tank's weekly adds nothing.
  jq -c '.models[0].pct = 50' "$CLIKAE_HOME/state/usage/claude/work.json" > "$TEST_HOME/w.json"
  mv "$TEST_HOME/w.json" "$CLIKAE_HOME/state/usage/claude/work.json"
  run --separate-stderr clikae usage claude
  [ "$(printf '%s\n' "$stderr" | tail -n 1)" = "claude 92" ] || { echo "below stderr: $stderr"; false; }
  # A last-known number is marked with "?".
  USAGE_NETFAIL=1 run --separate-stderr clikae usage claude --fresh
  [ "$(printf '%s\n' "$stderr" | tail -n 1)" = "claude 92?" ] || { echo "stderr: $stderr"; false; }
}
