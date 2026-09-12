#!/usr/bin/env bats
# tests/bats/dry-relay.bats — the dry-tank carry-onward stack:
#   • dry_store         — persist a live-caught limit so the board can read it later
#   • limit_tank_dry    — account-aware "is this tank out of fuel?" (contagion)
#   • next_tank         — circular, same-engine-first selector
# These power codex's red dot (its limit is exec-stdout-only) and the home board's
# "carry on to a fuelled tank" action. (`[[ … ]]` carry `|| false`; see README.)

load '../helpers'

_src() {
  export CLIKAE_LIB="$CLIKAE_TEST_ROOT/lib"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/dry_store.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/adapter_loader.sh"
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
}

# ISO-8601 UTC timestamp <N> minutes before the REAL clock — see R1-P2-3's note
# in home.bats's _iso_ago: a fixed far-future anchor made these fixtures
# unfalsifiable against the anchor-based expiry logic, not just "dry".
_iso_ago() { # <minutes>
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ
}

# "H(:MM)am/pm" the way vendor reset text renders it, computed <hours> ahead of
# the REAL clock in <zone>. R2-P2-1: a hardcoded absolute wall-clock hour here
# (`11pm`) with a now-10min anchor failed deterministically in the ten minutes
# before that wall-clock hour every day — anchoring the phrase to the clock too
# means the reset is always <hours> ahead of whenever the suite actually runs.
_phrase_ahead() { # <hours> <zone>
  local h="$1" tz="$2" ep hour minute suffix h12
  ep=$(( $(date -u +%s) + h * 3600 ))
  hour="$(TZ="$tz" date -d "@$ep" +%H 2>/dev/null || TZ="$tz" date -r "$ep" +%H)"
  minute="$(TZ="$tz" date -d "@$ep" +%M 2>/dev/null || TZ="$tz" date -r "$ep" +%M)"
  hour=$((10#$hour)); minute=$((10#$minute))
  suffix=am; [ "$hour" -ge 12 ] && suffix=pm
  h12=$(( hour % 12 )); [ "$h12" -eq 0 ] && h12=12
  if [ "$minute" -eq 0 ]; then printf '%d%s' "$h12" "$suffix"
  else printf '%d:%02d%s' "$h12" "$minute" "$suffix"; fi
}

# Seed a genuine claude limit marker (synthetic + isApiErrorMessage) under a tank.
# Recent-past observation (now-10min) keeps these account/selection fixtures
# dry (the reset phrase is still hours away); reset expiry itself is covered
# with a fixed clock in dry-reset-expiry.bats. Sets $_DRY_PHRASE to the exact
# text seeded, for tests that assert on it verbatim.
_seed_dry_tx() { # <engine> <profile>
  local p="$CLIKAE_HOME/profiles/$1/$2/projects/-Users-x"; mkdir -p "$p"
  _DRY_PHRASE="$(_phrase_ahead 6 Asia/Tokyo)"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit, resets '"$_DRY_PHRASE"' (Asia/Tokyo)"}]},"timestamp":"'"$(_iso_ago 10)"'"}' >> "$p/s.jsonl"
}

# Pin a tank's account label (the email adapter_account_label reads).
_seed_email() { # <engine> <profile> <email>
  printf '{"emailAddress": "%s"}\n' "$3" > "$CLIKAE_HOME/profiles/$1/$2/.claude.json"
}

# --- dry_store ----------------------------------------------------------------

@test "dry_store: mark then read returns dry + the verbatim reset phrase" {
  _src
  dry_store_mark codex H "try again at Jul 3rd 11:38 AM"
  run dry_store_read codex H
  [ "$status" -eq 0 ]
  [[ "$output" == *"try again at Jul 3rd 11:38 AM"* ]] || false
}

@test "dry_store: a clean tank reads not-dry" {
  _src
  run dry_store_read codex H
  [ "$status" -ne 0 ]
}

@test "dry_store: clear forgets the marker" {
  _src
  dry_store_mark codex H "resets soon"
  dry_store_clear codex H
  run dry_store_read codex H
  [ "$status" -ne 0 ]
}

@test "dry_store: a marker older than the TTL is stale (self-clears to not-dry)" {
  _src
  export CLIKAE_DRY_TTL=1
  dry_store_mark codex H "resets soon"
  sleep 2
  run dry_store_read codex H
  [ "$status" -ne 0 ]
  # and the stale file was lazily removed
  [ ! -f "$(dry_store_path codex H)" ]
}

@test "dry_store: an empty reset phrase still marks the tank dry" {
  _src
  dry_store_mark codex H ""
  run dry_store_read codex H
  [ "$status" -eq 0 ]
}

# --- limit_tank_dry : account contagion ---------------------------------------

@test "limit_tank_dry: a sibling on the SAME account reads dry when one is limited" {
  _src
  clikae init claude L
  clikae init claude MFC
  _seed_email claude L   same@example.com
  _seed_email claude MFC same@example.com
  _seed_dry_tx claude L            # only L has the marker
  # L is dry by its own transcript...
  run limit_tank_dry claude L
  [ "$status" -eq 0 ]
  # ...and MFC inherits it (same login, one shared quota) even with no marker.
  run limit_tank_dry claude MFC
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets $_DRY_PHRASE (Asia/Tokyo)"* ]] || false
}

@test "limit_tank_dry: a tank on a DIFFERENT account is NOT contaged" {
  _src
  clikae init claude L
  clikae init claude C
  _seed_email claude L same@example.com
  _seed_email claude C other@example.com
  _seed_dry_tx claude L
  run limit_tank_dry claude C
  [ "$status" -ne 0 ]
}

@test "limit_tank_dry: codex reads dry from the persisted store" {
  _src
  clikae init codex H
  dry_store_mark codex H "try again later"
  run limit_tank_dry codex H
  [ "$status" -eq 0 ]
  [[ "$output" == *"try again later"* ]] || false
}

# --- next_tank : same-engine-first + honest-when-all-dry ----------------------

@test "next_tank prefers a fuelled SAME-engine tank over a nearer cross-engine one" {
  _src
  clikae init claude a
  clikae init claude b
  clikae init codex x
  # Ring after claude/a is codex/x (nearer) then claude/b. Same-engine wins.
  printf 'claude/a\ncodex/x\nclaude/b\n' > "$CLIKAE_HOME/order"
  [ "$(next_tank claude a)" = "$(printf 'claude\tb')" ]
}

@test "next_tank falls to a cross-engine tank only when every same-engine tank is dry" {
  _src
  clikae init claude a
  clikae init codex x
  _seed_dry_tx claude a   # the only same-engine reserve besides current is... none
  printf 'claude/a\ncodex/x\n' > "$CLIKAE_HOME/order"
  # From claude/a: no other claude tank at all → cross to the fuelled codex/x.
  [ "$(next_tank claude a)" = "$(printf 'codex\tx')" ]
}

@test "next_tank returns nothing when the whole ring is dry (honest, no false hop)" {
  _src
  clikae init claude a
  clikae init claude b
  _seed_dry_tx claude a
  _seed_dry_tx claude b
  [ -z "$(next_tank claude a)" ]
}

@test "next_tank skips a SOLO tank (it's out of the fleet rotation)" {
  _src
  clikae init claude a
  clikae init claude b
  clikae init claude c
  clikae solo claude b                                   # b is standalone
  printf 'claude/a\nclaude/b\nclaude/c\n' > "$CLIKAE_HOME/order"
  # Ring after a is b (solo → skipped) then c. So the carry target is c, not b.
  [ "$(next_tank claude a)" = "$(printf 'claude\tc')" ]
}

# --- capture-time annotation (codex/agy snapshots read honestly) ---------------

@test "dry_store_epoch: returns the recorded epoch" {
  _src
  dry_store_mark codex H "Try again at 2026-06-05 07:00"
  run dry_store_epoch codex H
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]] || false
}

@test "dry_seen_suffix: builds a '· seen HH:MM' tag from an epoch" {
  _src
  T_DRY_SEEN="seen %s"
  run dry_seen_suffix 1780624464
  [ "$status" -eq 0 ]
  [[ "$output" == *"·"* ]] || false
  [[ "$output" == *"seen"* ]] || false
}

@test "dry_seen_suffix: empty/garbage epoch → no annotation (never invents a time)" {
  _src
  T_DRY_SEEN="seen %s"
  run dry_seen_suffix ""
  [ -z "$output" ]
  run dry_seen_suffix "nope"
  [ -z "$output" ]
}
