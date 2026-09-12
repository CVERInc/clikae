#!/usr/bin/env bats
load '../helpers'

_boot_expiry() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib" TZ=UTC
  source "$CLIKAE_LIB/core/log.sh"
  source "$CLIKAE_LIB/core/i18n.sh"
  source "$CLIKAE_LIB/core/profile_store.sh"
  source "$CLIKAE_LIB/core/dry_store.sh"
  source "$CLIKAE_LIB/core/limit.sh"
  source "$CLIKAE_LIB/commands/home.sh"
  # Keep all fixtures at noon, clear of midnight and minute rounding.
  real_now="$(date +%s)"
  fixed_now="$(_limit_at UTC "$(_limit_local UTC "$real_now" '%Y-%m-%d')" 12:00)"
  date() {
    if [ "$*" = +%s ]; then printf '%s\n' "$fixed_now"; else command date "$@"; fi
  }
  _limit_tank_account() { :; }
  clikae init codex expired >/dev/null 2>&1
  rollout="$CLIKAE_HOME/profiles/codex/expired/sessions/rollout-expiry.jsonl"
  mkdir -p "${rollout%/*}"
}

_limit_fixture() {
  local stamp
  stamp="$(_limit_local UTC "$((fixed_now - 1200))" '%Y-%m-%dT%H:%M:%SZ')"
  printf '{"timestamp":"%s","payload":{"codex_error_info":"usage_limit_exceeded","message":"try again at %s"}}\n' "$stamp" "$1" > "$rollout"
}

@test "reset ten minutes past: not dry, board yellow and unverified" {
  _boot_expiry
  _limit_fixture '11:50 AM'
  run limit_tank_dry codex expired
  [ "$status" -eq 1 ]
  local set
  set="$(list_all_profiles | limit_dry_set --include-unverified)"
  run _home_is_dryv "$set" codex expired
  [ "$status" -eq 1 ]
  __C_YELLOW=YELLOW
  _home_fuel_dotv "$set" codex expired
  [ "$_FDOT" = "YELLOW◐$__C_RESET" ]
  [ "$_FNOTE" = 'reset passed · unverified' ]
}

@test "reset ten minutes future: remains dry with vendor phrase" {
  _boot_expiry
  _limit_fixture '12:10 PM'
  run limit_tank_dry codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at 12:10 PM' ]
}

@test "unparseable reset keeps dry behavior" {
  _boot_expiry
  _limit_fixture 'some unknown time'
  run limit_tank_dry codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at some unknown time' ]
}

@test "carry selection can choose a tank whose reset passed" {
  _boot_expiry
  _limit_fixture '11:50 AM'
  order_list() { printf 'codex/current\ncodex/expired\n'; }
  tank_is_solo() { return 1; }
  run next_tank codex current
  [ "$status" -eq 0 ]
  [ "$output" = $'codex\texpired' ]
  _limit_fixture '12:10 PM'
  run next_tank codex current
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "successful turn clears the unverified evidence" {
  _boot_expiry
  _limit_fixture '11:50 AM'
  printf '{"timestamp":"%s","payload":{"type":"agent_message","message":"done"}}\n' \
    "$(_limit_local UTC "$fixed_now" '%Y-%m-%dT%H:%M:%SZ')" >> "$rollout"
  run _limit_tank_dry_self codex expired
  [ "$status" -eq 1 ]
}

@test "another engine's persisted parseable reset also becomes unverified" {
  _boot_expiry
  local marker
  marker="$(dry_store_path grok work)"
  mkdir -p "${marker%/*}"
  printf '%s\tresets 11:50am (UTC)\n' "$((fixed_now - 1200))" > "$marker"
  run _limit_tank_dry_self grok work
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
  run limit_tank_dry grok work
  [ "$status" -eq 1 ]
}

@test "status fuel note shares board verdict" {
  _boot_expiry
  source "$CLIKAE_LIB/commands/status.sh"
  _limit_fixture '11:50 AM'
  run _status_fuel_note codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
}

@test "undated reset remains expired the next day" {
  _boot_expiry
  _limit_fixture '11:50 AM'
  fixed_now=$((fixed_now + 86400))
  run _limit_tank_dry_self codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
}

@test "expired store evidence survives TTL until success clears it" {
  _boot_expiry
  local marker
  marker="$(dry_store_path grok work)"
  mkdir -p "${marker%/*}"
  printf '%s\tresets 11:50am (UTC)\n' "$((fixed_now - 1200))" > "$marker"
  fixed_now=$((fixed_now + 86400))
  run _limit_tank_dry_self grok work
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
  dry_store_clear grok work
  run _limit_tank_dry_self grok work
  [ "$status" -eq 1 ]
}

@test "burn reserve selector does not skip expired reset evidence" {
  _boot_expiry
  source "$CLIKAE_LIB/commands/burn.sh"
  _limit_fixture '11:50 AM'
  tank_is_solo() { return 1; }
  run _burn_next_same_engine codex '' '' CODEX_HOME 1
  [ "$status" -eq 0 ]
  [ "$output" = expired ]
}
