#!/usr/bin/env bats
# tests/bats/limit-reset.bats — limit_reset_epoch: the vendor's reset sentence
# turned into an instant, so a limited tank can be woken when the limit lifts.
#
# Two layers, and both are needed:
#   1. the CORPUS — every real reset phrase found in five accounts' transcripts,
#      with an answer key computed by python's zoneinfo rather than by the code
#      under test (tests/fixtures/limit-reset-phrases.tsv).
#   2. the CASES the corpus cannot contain. It is one person's real traffic, so
#      it is entirely (Asia/Tokyo) and has no DST in it — a version that ignored
#      the phrase's zone and read $TZ would pass all 175 rows on that machine.
#      Those are hand-built below and must not be deleted as redundant.
#
# `now` is always passed in. The function never reads the clock, which is what
# makes a thing that fires once every several hours testable at all.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_limit() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
}

# epoch of a wall-clock time in a named zone, computed with python (NOT with the
# bash helpers under test — an expectation the implementation did not write).
_at() {
  python3 - "$1" "$2" <<'PY'
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
tz, s = sys.argv[1], sys.argv[2]
print(int(datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZoneInfo(tz)).timestamp()))
PY
}

@test "reset: every real phrase in the corpus resolves to the expected instant" {
  _src_limit
  local fixture="$CLIKAE_TEST_ROOT/tests/fixtures/limit-reset-phrases.tsv"
  [ -s "$fixture" ] || false
  local now phrase want got rows=0 bad=0 firstbad=""
  while IFS=$'\t' read -r now phrase want; do
    case "$now" in \#*|"") continue ;; esac
    rows=$((rows + 1))
    if got="$(limit_reset_epoch "$phrase" "$now")" && [ "$got" = "$want" ]; then
      continue
    fi
    bad=$((bad + 1))
    [ -n "$firstbad" ] || firstbad="now=$now [$phrase] want=$want got=${got:-<unparsed>}"
  done < "$fixture"
  # A fixture that silently emptied would otherwise pass this test with 0 rows.
  [ "$rows" -ge 150 ] || { echo "corpus too small: $rows rows"; false; }
  [ "$bad" -eq 0 ] || { echo "$bad/$rows mismatched; first: $firstbad"; false; }
}

@test "reset: an undated time that already passed today means tomorrow" {
  _src_limit
  local now want got
  now="$(_at Asia/Tokyo '2026-08-12 23:00:00')"
  want="$(_at Asia/Tokyo '2026-08-13 03:50:00')"
  got="$(limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: now EXACTLY on the stated minute rolls forward, it does not return now" {
  # The tie is the dangerous input: a phrase is written at the moment the limit
  # fires, so "resets 3:50am" arriving AT 3:50am cannot mean "already open".
  _src_limit
  local now want got
  now="$(_at Asia/Tokyo '2026-08-12 03:50:00')"
  want="$(_at Asia/Tokyo '2026-08-13 03:50:00')"
  got="$(limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' "$now")"
  [ "$got" = "$want" ]
  [ "$got" != "$now" ]
}

@test "reset: a dated phrase with no year crosses into the next one" {
  _src_limit
  local now want got
  now="$(_at Asia/Tokyo '2026-12-31 23:00:00')"
  want="$(_at Asia/Tokyo '2027-01-02 05:00:00')"
  got="$(limit_reset_epoch 'resets Jan 2 at 5am (Asia/Tokyo)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: year inference skips a date that does not exist in that year" {
  # The guard this watches was added on reasoning and had NOTHING watching it —
  # every other test here stayed green with it removed. It matters because the
  # platforms disagree: GNU `date -d` rejects 2027-02-29, BSD `date -j -f`
  # silently makes it 2027-03-01 and exits 0. Asked for "Feb 29" from January
  # 2027, the answer is the next real one (2028); without the read-back check
  # macOS would answer 2027-03-01 and look confident about it.
  _src_limit
  local now want got
  now="$(_at Asia/Tokyo '2027-01-01 12:00:00')"
  want="$(_at Asia/Tokyo '2028-02-29 05:00:00')"
  got="$(limit_reset_epoch 'resets Feb 29 at 5am (Asia/Tokyo)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: the zone comes from the phrase, not from \$TZ" {
  # The whole corpus is Asia/Tokyo, so only a hand-built case can catch a version
  # that reads the ambient zone. Run it under a THIRD zone so neither the phrase's
  # zone nor the machine's can be right by accident.
  _src_limit
  local now want got
  now="$(_at UTC '2026-08-12 10:00:00')"
  want="$(_at America/New_York '2026-08-12 17:00:00')"
  got="$(TZ=Europe/Berlin limit_reset_epoch 'resets 5pm (America/New_York)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: a wall-clock time that DST deletes still yields a real instant" {
  # 2026-03-08 02:30 does not exist in America/New_York. There is no correct
  # answer, only a sane one: we require a resolvable instant on that same day,
  # not a failure and not a silent 1970.
  _src_limit
  local now got day
  now="$(_at America/New_York '2026-03-08 01:00:00')"
  got="$(limit_reset_epoch 'resets 2:30am (America/New_York)' "$now")"
  [ -n "$got" ]
  [ "$got" -gt "$now" ]
  day="$(TZ=America/New_York date -d "@$got" '+%Y-%m-%d' 2>/dev/null \
        || TZ=America/New_York date -r "$got" '+%Y-%m-%d')"
  [ "$day" = "2026-03-08" ]
}

@test "reset: 12am and 12pm are midnight and noon, not both noon" {
  _src_limit
  local now a b
  now="$(_at Asia/Tokyo '2026-08-12 00:02:00')"
  a="$(limit_reset_epoch 'resets 12:10am (Asia/Tokyo)' "$now")"
  b="$(limit_reset_epoch 'resets 12pm (Asia/Tokyo)' "$now")"
  [ "$a" = "$(_at Asia/Tokyo '2026-08-12 00:10:00')" ]
  [ "$b" = "$(_at Asia/Tokyo '2026-08-12 12:00:00')" ]
}

@test "reset: the same phrase and now give the same answer every call" {
  # BSD `date -j -f` fills fields the format omits from the CURRENT time, so a
  # '%H:%M' format drifts by the wall-clock second. This caught that.
  _src_limit
  local a b c
  a="$(limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' 1786460531)"
  b="$(limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' 1786460531)"
  c="$(limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' 1786460531)"
  [ "$a" = "$b" ]
  [ "$b" = "$c" ]
  [ "$((a % 60))" -eq 0 ]
}

@test "reset: unparseable input fails loudly instead of guessing" {
  # A silent 0 would schedule a wake-up for 1970 and fire immediately, which is
  # worse than not scheduling: "I don't know when" must not become "right now".
  _src_limit
  run limit_reset_epoch 'resets 3:50am' 1786460531        # no zone
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run limit_reset_epoch 'nothing useful here' 1786460531
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run limit_reset_epoch '' 1786460531
  [ "$status" -ne 0 ]
  run limit_reset_epoch 'resets 3:50am (Asia/Tokyo)' ''   # no clock given
  [ "$status" -ne 0 ]
}

@test "reset: a limit sentence carrying the phrase parses the same as the phrase" {
  _src_limit
  local now a b
  now="$(_at Asia/Tokyo '2026-08-12 00:02:00')"
  a="$(limit_reset_epoch 'resets 5pm (Asia/Tokyo)' "$now")"
  b="$(limit_reset_epoch "hit your weekly limit · resets 5pm (Asia/Tokyo)" "$now")"
  [ "$a" = "$b" ]
}
