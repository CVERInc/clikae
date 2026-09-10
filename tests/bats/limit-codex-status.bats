#!/usr/bin/env bats
# tests/bats/limit-codex-status.bats — codex's OWN proactive usage status (the
# 5h/weekly windows its `/status` panel renders, e.g. "5h limit:  [████] 100%
# left (resets 05:14)" / "Weekly limit: [████] 95% left (resets 22:12 on 15
# Sep)"), turned into the same red/yellow/green light and reset instant the
# claude path already has. See lib/core/limit.sh's "codex's OWN proactive
# usage status" section and docs/DESIGN-board-fuel-dots.md.
#
# limit_codex_status / _limit_codex_rate_limits — the STRUCTURED source
# clikae actually wires up: codex's own `rate_limits` object, persisted into
# the rollout transcript by a `token_count` event, with an already-absolute
# `resets_at` epoch (no timezone guessing needed there at all).
# `_limit_codex_render_reset` renders that absolute epoch back into codex's
# own phrase grammar (the only direction that ships — see the note just
# below the helpers).
#
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_limit() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh"   # transcript_tail
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
}

# epoch of a wall-clock LOCAL time (no zone in the phrase — codex renders in
# the machine's own local time, so the test pins $TZ and computes the
# expectation in that SAME zone via python's zoneinfo, never via the code
# under test).
_at() {
  python3 - "$1" "$2" <<'PY'
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
tz, s = sys.argv[1], sys.argv[2]
print(int(datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZoneInfo(tz)).timestamp()))
PY
}

# --- _limit_codex_render_reset: epoch -> codex's own phrase grammar ---------
# (The text -> epoch direction, limit_codex_status_reset_epoch, was deleted
# in round-1 review 2026-09-12 — dead code, no real caller anywhere in
# lib/bin/scripts, only its own tests. See docs/DESIGN-board-fuel-dots.md.)

@test "codex render reset: undated epoch within ~20h renders the short form" {
  _src_limit
  local now ep got
  now="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-12 23:00:00')"
  ep="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-13 05:14:00')"
  got="$(TZ=Asia/Tokyo _limit_codex_render_reset "$ep" "$now")"
  [ "$got" = "resets 05:14" ]
}

@test "codex render reset: an epoch a day or more out renders the dated form" {
  _src_limit
  local now ep got
  now="$(TZ=UTC _at UTC '2026-09-10 10:00:00')"
  ep="$(TZ=UTC _at UTC '2026-09-15 22:12:00')"
  got="$(TZ=UTC _limit_codex_render_reset "$ep" "$now")"
  [ "$got" = "resets 22:12 on 15 Sep" ]
}

# --- P1-1 (2026-09-12 round-1 review): time validity -------------------------
# A rate_limits reading whose window's resets_at has already passed has
# REFILLED server-side — its used_percent must never be relayed as current,
# and its own instant must never be rendered as a future reset.

@test "codex render reset: a past epoch is never rendered, dated or not (P1-1)" {
  _src_limit
  local now ep
  now="$(TZ=UTC _at UTC '2026-09-10 16:40:00')"
  # 2h in the past — falls well outside the old -60s..72000s short-form
  # window, which used to fall through to the DATED branch and print this
  # already-past instant as if it were a future date.
  ep="$(TZ=UTC _at UTC '2026-09-10 14:40:00')"
  run _limit_codex_render_reset "$ep" "$now"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "codex window expired: 60s clock-skew boundary" {
  _src_limit
  local now
  now="$(TZ=UTC _at UTC '2026-09-10 12:00:00')"
  # exactly 60s behind now: still within the clock-skew tolerance, NOT expired.
  run _limit_codex_window_expired "$((now - 60))" "$now"
  [ "$status" -ne 0 ]
  # 61s behind now: expired.
  run _limit_codex_window_expired "$((now - 61))" "$now"
  [ "$status" -eq 0 ]
  # exactly now: not expired (matches _limit_codex_render_reset's own boundary).
  run _limit_codex_window_expired "$now" "$now"
  [ "$status" -ne 0 ]
}

@test "limit_codex_status: a 5h window that reset 2h ago reads back FULL, not its stale red (P1-1)" {
  # The exact repro from round-1 review: a tank burned to 100% used, whose 5h
  # window reset two hours before we read it, must show green/100% left, not
  # the red/0% left its last recorded event still says.
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/refilled" now expired_reset
  now="$(TZ=UTC _at UTC '2026-09-10 16:40:00')"
  expired_reset="$(TZ=UTC _at UTC '2026-09-10 14:40:00')"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":100.0,"window_minutes":300,"resets_at":'"$expired_reset"'}' 'null')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "green" ]
  [[ "$note" == *"100% left"* ]] || false
  [ -z "$reset" ]
}

@test "limit_codex_status: 5h expired + weekly still valid -> light follows the VALID window only (P1-1)" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/mixed" now expired_reset weekly_reset
  now="$(TZ=UTC _at UTC '2026-09-10 16:40:00')"
  expired_reset="$(TZ=UTC _at UTC '2026-09-10 14:40:00')"    # 2h in the past: refilled
  weekly_reset="$(TZ=UTC _at UTC '2026-09-17 10:00:00')"     # still ahead
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":100.0,"window_minutes":300,"resets_at":'"$expired_reset"'}' \
        '{"used_percent":95.0,"window_minutes":10080,"resets_at":'"$weekly_reset"'}')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "yellow" ]                       # 5h refilled to 100% left; weekly's genuine 5% left is tighter
  [[ "$note" == *"5h 100% left"* ]] || false     # refilled side shows 100% left, no reset text
  [[ "$note" != *"5h 100% left (resets"* ]] || false
  [[ "$note" == *"weekly"*"% left (resets"* ]] || false
  [[ "$reset" == "resets"*"on 17 Sep"* ]] || false
}

@test "limit_codex_status: BOTH windows expired -> full tank, green, no reset (P1-1)" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/bothexpired" now r1 r2
  now="$(TZ=UTC _at UTC '2026-09-10 16:40:00')"
  r1="$(TZ=UTC _at UTC '2026-09-10 14:40:00')"
  r2="$(TZ=UTC _at UTC '2026-09-09 10:00:00')"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":100.0,"window_minutes":300,"resets_at":'"$r1"'}' \
        '{"used_percent":100.0,"window_minutes":10080,"resets_at":'"$r2"'}')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "green" ]
  [[ "$note" == *"100% left"* ]] || false
  [ -z "$reset" ]
}

@test "limit_codex_status: a reset exactly AT now is still a valid, renderable reading (P1-1 boundary)" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/exactnow" now
  now="$(TZ=UTC _at UTC '2026-09-10 12:00:00')"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":'"$now"'}' 'null')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "green" ]
  [[ "$note" == *"5h 90% left (resets"* ]] || false
  [ -n "$reset" ]
}

# --- limit_codex_status_light: never a fake green ----------------------------

@test "codex status light: 100% left is green" {
  _src_limit
  run limit_codex_status_light 0 ""
  [ "$status" -eq 0 ]
  [ "$output" = "green" ]
}

@test "codex status light: a 5h window at 0% left (100% used) is red" {
  _src_limit
  run limit_codex_status_light 100 5
  [ "$status" -eq 0 ]
  [ "$output" = "red" ]
}

@test "codex status light: light is the TIGHTER of the two windows" {
  _src_limit
  # 5h has plenty left, weekly is fully exhausted — the weekly window is the
  # one that actually stops you, so red must win even though primary alone
  # would read healthy.
  run limit_codex_status_light 10 100
  [ "$status" -eq 0 ]
  [ "$output" = "red" ]
  # 5h has plenty left, weekly is just low (not exhausted) — yellow, not green.
  run limit_codex_status_light 10 87
  [ "$status" -eq 0 ]
  [ "$output" = "yellow" ]
}

@test "codex status light: no data at all is unknown, never a guessed colour" {
  _src_limit
  run limit_codex_status_light "" ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- the structured source: rate_limits inside a real rollout's token_count --
# `codex exec` (headless burn, not just the interactive TUI) persists this —
# confirmed against a real rollout on 2026-09-10 whose session_meta says
# originator "codex_exec". Fixture mirrors that shape exactly.

_seed_codex_token_count() {
  local dir="$1" name="$2"; shift 2
  mkdir -p "$dir/sessions/2026/09/10"
  : > "$dir/sessions/2026/09/10/rollout-$name.jsonl"
  local l
  for l in "$@"; do
    printf '%s\n' "$l" >> "$dir/sessions/2026/09/10/rollout-$name.jsonl"
  done
}

_codex_token_count_line() {
  # $1 timestamp, $2 primary-json-or-null, $3 secondary-json-or-null
  printf '{"timestamp": "%s", "type": "event_msg", "payload": {"type": "token_count", "info": {}, "rate_limits": {"limit_id": "codex", "limit_name": null, "primary": %s, "secondary": %s, "credits": {"has_credits": false}}}}' \
    "$1" "$2" "$3"
}

@test "codex rate_limits: a healthy pair of windows reads back verbatim" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/crazy"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T10:00:00.000Z \
        '{"used_percent":0.0,"window_minutes":300,"resets_at":1791471936}' \
        '{"used_percent":5.0,"window_minutes":10080,"resets_at":1791999999}')"
  run _limit_codex_rate_limits "$d"
  [ "$status" -eq 0 ]
  local pu pw pr su sw sr
  IFS=$'\037' read -r pu pw pr su sw sr <<< "$output"
  [ "$pu" = "0.0" ]; [ "$pw" = "300" ]; [ "$pr" = "1791471936" ]
  [ "$su" = "5.0" ]; [ "$sw" = "10080" ]; [ "$sr" = "1791999999" ]
}

@test "codex rate_limits: the NEWEST token_count event wins, not the first" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/crazy"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":1791471936}' 'null')" \
    "$(_codex_token_count_line 2026-09-10T10:30:00.000Z \
        '{"used_percent":40.0,"window_minutes":300,"resets_at":1791475000}' 'null')"
  run _limit_codex_rate_limits "$d"
  [ "$status" -eq 0 ]
  local pu pw pr su sw sr
  IFS=$'\037' read -r pu pw pr su sw sr <<< "$output"
  [ "$pu" = "40.0" ]
  [ "$pr" = "1791475000" ]
}

@test "codex rate_limits: a real free-tier shape (30-day window, secondary null) is NOT mislabeled" {
  # Real sample, this machine, 2026-09-10: limit_id "codex", window_minutes
  # 43200 (30 days) sitting in PRIMARY, secondary always null. Position must
  # never be read as "primary=5h" — the window's own length decides the label.
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/free"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T10:00:00.000Z \
        '{"used_percent":24.0,"window_minutes":43200,"resets_at":1791471936}' 'null')"
  run _limit_codex_window_label 43200
  [ "$status" -eq 0 ]
  [ "$output" = "30d" ]
  run limit_codex_status_note 24.0 43200 1791471936 "" "" "" 1700000000
  [[ "$output" == *"30d"* ]] || false
  [[ "$output" != *"5h"* ]] || false
  [[ "$output" != *"weekly"* ]] || false
}

@test "codex rate_limits: no codex sessions at all -> not detectable, never a guessed reading" {
  _src_limit
  run _limit_codex_rate_limits "$CLIKAE_HOME/profiles/codex/nothing"
  [ "$status" -ne 0 ]
  run limit_codex_status "$CLIKAE_HOME/profiles/codex/nothing" 1700000000
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "limit_codex_status: combines rate_limits into light + note + the tighter reset" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/crazy" now
  now="$(TZ=UTC _at UTC '2026-09-10 10:00:00')"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:59:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":'"$(TZ=UTC _at UTC '2026-09-10 15:00:00')"'}' \
        '{"used_percent":100.0,"window_minutes":10080,"resets_at":'"$(TZ=UTC _at UTC '2026-09-17 10:00:00')"'}')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "red" ]                       # weekly (0% left) is the tighter window
  [[ "$note" == *"5h"* ]] || false
  [[ "$note" == *"weekly"* ]] || false
  [[ "$reset" == "resets"*"on 17 Sep"* ]] || false   # the WEEKLY window's own reset, not the 5h one
}

# --- P1-2 (2026-09-12 round-1 review): the newest event must survive a fat tail

@test "codex rate_limits: the newest event is not lost behind >700 KB of trailing output (P1-2)" {
  # Fixture: an OLDER, already-expired rate_limits event in one rollout, and a
  # FRESH, healthy one in another — but the fresh one is followed by >700 KB
  # of unrelated trailing lines (the shape of a codex session that keeps
  # writing tool output after its last token_count event). The old fixed
  # 512 KiB transcript_tail would only see the trailing noise, never the
  # fresh event, and the stale/older event would silently win.
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/fattail"
  mkdir -p "$d/sessions/2026/09/10"
  local old="$d/sessions/2026/09/10/rollout-old.jsonl"
  local new="$d/sessions/2026/09/10/rollout-new.jsonl"
  _codex_token_count_line 2026-09-10T08:00:00.000Z \
      '{"used_percent":100.0,"window_minutes":300,"resets_at":1600000000}' 'null' \
    > "$old"
  printf '\n' >> "$old"
  _codex_token_count_line 2026-09-10T12:00:00.000Z \
      '{"used_percent":5.0,"window_minutes":300,"resets_at":1900000000}' 'null' \
    > "$new"
  printf '\n' >> "$new"
  # >700 KB of trailing filler AFTER the fresh event — well past the old
  # 512 KiB fixed tail window.
  head -c 737280 /dev/zero | tr '\0' 'x' >> "$new"
  printf '\n' >> "$new"

  run _limit_codex_rate_limits "$d"
  [ "$status" -eq 0 ]
  local pu pw pr su sw sr
  IFS=$'\037' read -r pu pw pr su sw sr <<< "$output"
  [ "$pu" = "5.0" ]        # the FRESH reading, not the stale 100.0
  [ "$pr" = "1900000000" ]
}

@test "transcript_tail_scan: grows the window until the pattern is inside it" {
  _src_limit
  local f="$BATS_TEST_TMPDIR/big.jsonl"
  printf '{"marker":"needle"}\n' > "$f"
  head -c 800000 /dev/zero | tr '\0' 'y' >> "$f"
  printf '\n' >> "$f"
  run transcript_tail_scan "$f" '"marker": *"needle"' 524288
  [ "$status" -eq 0 ]
  [[ "$output" == *'"marker":"needle"'* ]] || false
}

@test "transcript_tail_scan: a pattern that never occurs still returns (the whole file, not an error)" {
  _src_limit
  local f="$BATS_TEST_TMPDIR/small.jsonl"
  printf 'no match here\n' > "$f"
  run transcript_tail_scan "$f" 'NEVER_MATCHES' 524288
  [ "$status" -eq 0 ]
  [[ "$output" == *'no match here'* ]] || false
}

# --- P2-1 (2026-09-12 round-1 review): the cached redraw path ---------------

@test "limit_codex_status_cached: matches the uncached reading for the same store" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/cachedhealthy" now cache
  now="$(TZ=UTC _at UTC '2026-09-10 10:00:00')"
  cache="$CLIKAE_HOME/cache/codex/cachedhealthy"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":'"$(TZ=UTC _at UTC '2026-09-10 15:00:00')"'}' 'null')"
  local direct cached
  TZ=UTC direct="$(limit_codex_status "$d" "$now")"
  TZ=UTC cached="$(limit_codex_status_cached "$d" "$now" "$cache")"
  [ "$direct" = "$cached" ]
  [ -f "$cache" ]
}

@test "limit_codex_status_cached: a new rollout event invalidates the cache" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/cachedgrows" now cache first second
  now="$(TZ=UTC _at UTC '2026-09-10 10:00:00')"
  cache="$CLIKAE_HOME/cache/codex/cachedgrows"
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:00:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":'"$(TZ=UTC _at UTC '2026-09-10 15:00:00')"'}' 'null')"
  first="$(TZ=UTC limit_codex_status_cached "$d" "$now" "$cache")"
  [[ "$first" == "green"* ]] || false
  # Force the new file's mtime a second ahead so the cache key (count+mtime)
  # is guaranteed to differ even on a coarse-grained filesystem clock.
  sleep 1
  _seed_codex_token_count "$d" b \
    "$(_codex_token_count_line 2026-09-10T09:30:00.000Z \
        '{"used_percent":100.0,"window_minutes":300,"resets_at":'"$(TZ=UTC _at UTC '2026-09-10 15:00:00')"'}' 'null')"
  second="$(TZ=UTC limit_codex_status_cached "$d" "$now" "$cache")"
  [[ "$second" == "red"* ]] || false
}

# --- P3-1 (2026-09-12 round-1 review): rounding must not be optimistic ------

@test "_limit_codex_left: a non-zero fraction rounds USED up, so 99.5 is already red-worthy (P3-1)" {
  _src_limit
  run _limit_codex_left 99.5
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]                # ceil(99.5) used -> 0% left, same as 100.0
  run limit_codex_status_light 99.5 ""
  [ "$status" -eq 0 ]
  [ "$output" = "red" ]
  # a whole-number (or all-zero-fraction) percentage is unaffected.
  run _limit_codex_left 40.00
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
  run _limit_codex_left 40
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

# --- P3-2 (2026-09-12 round-1 review): label by the REAL weekly boundary ----

@test "_limit_codex_window_label: a 14-day window is NOT mislabeled weekly (P3-2)" {
  _src_limit
  run _limit_codex_window_label 10080
  [ "$status" -eq 0 ]
  [ "$output" = "weekly" ]
  run _limit_codex_window_label 10081
  [ "$status" -eq 0 ]
  [ "$output" = "7d" ]
  run _limit_codex_window_label 20160
  [ "$status" -eq 0 ]
  [ "$output" = "14d" ]
}

# --- P3-4 (2026-09-12 round-1 review): fall back to the OTHER side's reset --

@test "limit_codex_status: the tighter side's own reset is missing -> falls back to the other side's (P3-4)" {
  _src_limit
  local d="$CLIKAE_HOME/profiles/codex/fallback" now
  now="$(TZ=UTC _at UTC '2026-09-10 10:00:00')"
  # weekly (tighter, 5% left) has NO resets_at on disk; 5h (90% left) does.
  _seed_codex_token_count "$d" a \
    "$(_codex_token_count_line 2026-09-10T09:59:00.000Z \
        '{"used_percent":10.0,"window_minutes":300,"resets_at":'"$(TZ=UTC _at UTC '2026-09-10 15:00:00')"'}' \
        '{"used_percent":95.0,"window_minutes":10080}')"
  TZ=UTC run limit_codex_status "$d" "$now"
  [ "$status" -eq 0 ]
  local light note reset
  IFS=$'\037' read -r light note reset <<< "$output"
  [ "$light" = "yellow" ]
  [ -n "$reset" ]                     # falls back to the 5h window's own reset
  [[ "$reset" == "resets 15:00" ]] || false
}
