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
  # R1-P2-1: the dry set is now computed ONCE by the caller and passed in,
  # not re-scanned inside _status_fuel_note — see status.sh.
  local dry; dry="$(list_all_profiles | limit_dry_set --include-unverified)"
  run _status_fuel_note codex expired "$dry"
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
}

@test "R2-P3-5: status fuel note called with a missing 3rd arg says nothing, not 'fine'" {
  _boot_expiry
  source "$CLIKAE_LIB/commands/status.sh"
  _limit_fixture '11:50 AM'
  # Missing dry-set arg entirely (a future renderer forgetting it) must not be
  # indistinguishable from "this tank has no caution" — guarded by arg count.
  run _status_fuel_note codex expired
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

# --- R1-P1-2: a retained marker is not immortal -------------------------------
#
# Round 1 gave dry_store_read a --retain-stale flag so expired-but-parseable
# evidence could survive its normal 6h TTL as "unverified" until a successful
# run cleared it — but codex's OWN raw scanner (_limit_codex_dry) fell through
# to that retained store REGARDLESS of whether the transcript itself already
# showed a real recovery, so a real success sitting right there in the rollout
# never reached dry_store_clear. Two independent exits now bound it:
#   1. a real transcript turn observed AFTER the limit clears the store marker
#      too (not just the transcript's own verdict) — even a marker an unrelated
#      headless run left behind.
#   2. CLIKAE_DRY_MAX_RETAIN is a hard, unconditional ceiling for the case
#      nothing is ever observed to clear it explicitly.

@test "a real transcript recovery clears an unrelated stale store marker too" {
  _boot_expiry
  _limit_fixture '11:50 AM'
  # A store marker an EARLIER, unrelated headless run left behind — different
  # reset text, so it is not just re-deriving the transcript's own phrase.
  local marker; marker="$(dry_store_path codex expired)"
  mkdir -p "${marker%/*}"
  printf '%s\tresets 1:00am (UTC)\n' "$((fixed_now - 1200))" > "$marker"
  # A real turn AFTER the limit — genuine transcript recovery.
  printf '{"timestamp":"%s","payload":{"type":"agent_message","message":"done"}}\n' \
    "$(_limit_local UTC "$fixed_now" '%Y-%m-%dT%H:%M:%SZ')" >> "$rollout"
  run _limit_tank_dry_self codex expired
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

# --- R2-P1-3: only a recovery NEWER than the marker may clear it --------------
#
# The test above only covers the recovery being the NEWER of the two. Round 2
# added the rc=2 exit unconditionally, so ANY transcript recovery cleared ANY
# stale marker regardless of which was newer — but a headless `codex exec`
# limit never reaches the transcript at all (burn.sh's dry_store_mark is its
# only record), so a days-old interactive recovery and a marker burn wrote
# moments ago are independent facts. Timestamp order must be the tiebreaker.

@test "a headless marker newer than a stale transcript recovery survives" {
  _boot_expiry
  # An interactive limit + recovery from days ago — real, but ancient.
  printf '{"timestamp":"%s","payload":{"codex_error_info":"usage_limit_exceeded","message":"try again at 1:00 AM (UTC)"}}\n' \
    "$(_limit_local UTC "$((fixed_now - 4 * 86400))" '%Y-%m-%dT%H:%M:%SZ')" > "$rollout"
  printf '{"timestamp":"%s","payload":{"type":"agent_message","message":"done"}}\n' \
    "$(_limit_local UTC "$((fixed_now - 3 * 86400))" '%Y-%m-%dT%H:%M:%SZ')" >> "$rollout"
  # burn just wrote a FRESH headless marker, right now, for a DIFFERENT limit.
  dry_store_mark codex expired 'try again at 11:50 PM (UTC)'
  local marker; marker="$(dry_store_path codex expired)"
  run limit_tank_dry codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'try again at 11:50 PM (UTC)' ]
  [ -e "$marker" ]
  # burn's own selection set must still carry this tank as dry.
  local set; set="$(list_all_profiles | limit_dry_set)"
  run _home_is_dryv "$set" codex expired
  [ "$status" -eq 0 ]
}

@test "a transcript recovery newer than the marker still clears it" {
  _boot_expiry
  printf '{"timestamp":"%s","payload":{"codex_error_info":"usage_limit_exceeded","message":"try again at 1:00 AM (UTC)"}}\n' \
    "$(_limit_local UTC "$((fixed_now - 4 * 86400))" '%Y-%m-%dT%H:%M:%SZ')" > "$rollout"
  # This time the marker PREDATES the recovery below.
  local marker; marker="$(dry_store_path codex expired)"
  mkdir -p "${marker%/*}"
  printf '%s\ttry again at 11:50 PM (UTC)\n' "$((fixed_now - 5 * 86400))" > "$marker"
  printf '{"timestamp":"%s","payload":{"type":"agent_message","message":"done"}}\n' \
    "$(_limit_local UTC "$fixed_now" '%Y-%m-%dT%H:%M:%SZ')" >> "$rollout"
  run limit_tank_dry codex expired
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "a codex tank with ONLY a retained store marker still hits CLIKAE_DRY_MAX_RETAIN" {
  # No rollout evidence at all here (unlike the test above) — codex's raw
  # scanner finds nothing and falls through to the store, same as a headless
  # `codex exec` limit nothing else ever observes a recovery for. The store's
  # own hard cap is the only thing that can ever turn this tank green again.
  _boot_expiry
  CLIKAE_DRY_MAX_RETAIN=$((3 * 86400))
  local marker stamp; marker="$(dry_store_path codex expired)"; stamp="$fixed_now"
  mkdir -p "${marker%/*}"
  printf '%s\tresets 12:10pm (UTC)\n' "$stamp" > "$marker"
  fixed_now=$((stamp + CLIKAE_DRY_MAX_RETAIN - 1))
  run _limit_tank_dry_self codex expired
  [ "$status" -eq 0 ]
  [ "$output" = 'reset passed · unverified' ]
  fixed_now=$((stamp + CLIKAE_DRY_MAX_RETAIN))
  run _limit_tank_dry_self codex expired
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "a retained third-party marker with no engine dry_self path also hits the cap" {
  # Same as above but through an engine with no transcript source at all (grok)
  # — the cap lives in dry_store_read itself, not in codex's transcript branch,
  # so it must hold for every engine that only ever has a persisted marker.
  _boot_expiry
  CLIKAE_DRY_MAX_RETAIN=$((3 * 86400))
  local marker; marker="$(dry_store_path grok work)"
  mkdir -p "${marker%/*}"
  printf '%s\tresets 11:50am (UTC)\n' "$((fixed_now - 1200))" > "$marker"
  fixed_now=$((fixed_now + CLIKAE_DRY_MAX_RETAIN))
  run _limit_tank_dry_self grok work
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}
