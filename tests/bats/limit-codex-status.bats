#!/usr/bin/env bats
# tests/bats/limit-codex-status.bats — codex's OWN proactive usage status (the
# 5h/weekly windows its `/status` panel renders, e.g. "5h limit:  [████] 100%
# left (resets 05:14)" / "Weekly limit: [████] 95% left (resets 22:12 on 15
# Sep)"), turned into the same red/yellow/green light and reset instant the
# claude path already has. See lib/core/limit.sh's "codex's OWN proactive
# usage status" section and docs/DESIGN-board-fuel-dots.md.
#
# Two layers, same split as limit-reset.bats:
#   1. limit_codex_status_reset_epoch — the TEXT parser (no transcript in
#      sight), for a captured status line.
#   2. limit_codex_status / _limit_codex_rate_limits — the STRUCTURED source
#      clikae actually wires up: codex's own `rate_limits` object, persisted
#      into the rollout transcript by a `token_count` event, with an already-
#      absolute `resets_at` epoch (no timezone guessing needed there at all).
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

# --- limit_codex_status_reset_epoch: the text parser -------------------------

@test "codex status reset: undated HH:MM resolves to the next occurrence, local time" {
  _src_limit
  local now want got
  now="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-12 23:00:00')"
  want="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-13 05:14:00')"
  got="$(TZ=Asia/Tokyo limit_codex_status_reset_epoch 'resets 05:14' "$now")"
  [ "$got" = "$want" ]
}

@test "codex status reset: a 5h window at 0% left rolls PAST MIDNIGHT to tomorrow" {
  # Fixture: "5h limit:  [████] 0% left (resets 05:14)" seen at 23:50 — the
  # window's own reset is less than 24h out and on the OTHER side of
  # midnight; this must not be read as 5h14m in the past.
  _src_limit
  local now want got line pct phrase epoch
  now="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-09-10 23:50:00')"
  want="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-09-11 05:14:00')"
  got="$(TZ=Asia/Tokyo limit_codex_status_reset_epoch 'resets 05:14' "$now")"
  [ "$got" = "$want" ]
  [ "$got" -gt "$now" ]

  line='5h limit:  [████] 0% left (resets 05:14)'
  TZ=Asia/Tokyo run limit_codex_status_line "$line" "$now"
  [ "$status" -eq 0 ]
  IFS=$'\037' read -r pct phrase epoch <<< "$output"
  [ "$pct" = "0" ]
  [ "$phrase" = "resets 05:14" ]
  [ "$epoch" = "$want" ]
}

@test "codex status reset: now EXACTLY on the stated minute rolls forward (never 'right now')" {
  _src_limit
  local now want got
  now="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-12 05:14:00')"
  want="$(TZ=Asia/Tokyo _at Asia/Tokyo '2026-08-13 05:14:00')"
  got="$(TZ=Asia/Tokyo limit_codex_status_reset_epoch 'resets 05:14' "$now")"
  [ "$got" = "$want" ]
  [ "$got" != "$now" ]
}

@test "codex status reset: dated 'HH:MM on D Mon' crosses a month/year boundary" {
  # Fixture: "Weekly limit: [████] 95% left (resets 22:12 on 15 Sep)" — read
  # from well after this year's Sep 15 already passed, so the closest REAL
  # occurrence is next year's.
  _src_limit
  local now want got line pct phrase epoch
  now="$(TZ=UTC _at UTC '2026-09-20 00:00:00')"
  want="$(TZ=UTC _at UTC '2027-09-15 22:12:00')"
  got="$(TZ=UTC limit_codex_status_reset_epoch 'resets 22:12 on 15 Sep' "$now")"
  [ "$got" = "$want" ]

  line='Weekly limit: [████] 95% left (resets 22:12 on 15 Sep)'
  TZ=UTC run limit_codex_status_line "$line" "$now"
  [ "$status" -eq 0 ]
  IFS=$'\037' read -r pct phrase epoch <<< "$output"
  [ "$pct" = "95" ]
  [ "$phrase" = "resets 22:12 on 15 Sep" ]
  [ "$epoch" = "$want" ]
}

@test "codex status reset: a dated phrase just barely in the past this year still means THIS year" {
  _src_limit
  local now want got
  now="$(TZ=UTC _at UTC '2026-09-16 00:00:00')"   # only ~1.5h after the stated time
  want="$(TZ=UTC _at UTC '2026-09-15 22:12:00')"
  got="$(TZ=UTC limit_codex_status_reset_epoch 'resets 22:12 on 15 Sep' "$now")"
  [ "$got" = "$want" ]
}

@test "codex status reset: English month table is locale-safe (never asks \`date\` to parse a name)" {
  _src_limit
  # now pinned to New Year's Day so EVERY month's 10th, this same year, is
  # still ahead of it — one fixed expected year for all twelve rows.
  local now pairs mon num got want
  now="$(TZ=UTC _at UTC '2026-01-01 00:00:00')"
  # All 12, so a table typo can't hide behind the two months the other tests use.
  pairs="Jan 01
Feb 02
Mar 03
Apr 04
May 05
Jun 06
Jul 07
Aug 08
Sep 09
Oct 10
Nov 11
Dec 12"
  while IFS=' ' read -r mon num; do
    [ -n "$mon" ] || continue
    want="$(TZ=UTC _at UTC "2026-${num}-10 12:00:00")"
    got="$(LC_ALL=de_DE.UTF-8 TZ=UTC limit_codex_status_reset_epoch "resets 12:00 on 10 $mon" "$now")"
    [ "$got" = "$want" ] || { echo "month=$mon got=$got want=$want"; false; }
  done <<< "$pairs"
}

@test "codex status reset: unparseable input fails loudly, never a guessed instant" {
  _src_limit
  run limit_codex_status_reset_epoch 'usage information unavailable' 1700000000
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run limit_codex_status_reset_epoch '' 1700000000
  [ "$status" -ne 0 ]
  run limit_codex_status_reset_epoch 'resets 05:14' ''
  [ "$status" -ne 0 ]
  run limit_codex_status_reset_epoch 'resets 25:99' 1700000000   # not a real clock time
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "codex status line: 100% left parses with no reset needed to be meaningful" {
  _src_limit
  run limit_codex_status_line '5h limit:  [████] 100% left (resets 05:14)' 1700000000
  [ "$status" -eq 0 ]
  local pct phrase epoch
  IFS=$'\037' read -r pct phrase epoch <<< "$output"
  [ "$pct" = "100" ]
}

@test "codex status line: a line with no percentage is not codex's status shape" {
  _src_limit
  run limit_codex_status_line 'Just chatting about usage limits today.' 1700000000
  [ "$status" -ne 0 ]
  [ -z "$output" ]
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
