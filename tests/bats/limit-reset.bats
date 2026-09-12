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
  # Every claude row here is zoned (Asia/Tokyo), so ambient TZ never mattered to
  # them — but R1-P2-2 added two codex rows that carry NO zone at all (codex's
  # documented behavior), so THEIR expected_epoch is only correct under one
  # ambient zone. Pin it so the corpus is deterministic on every machine/CI,
  # not just wherever this was authored.
  TZ=UTC
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

@test "reset: a wall-clock time that DST deletes resolves the same on every OS" {
  # 2026-03-08 02:30 does not exist in America/New_York. Left to themselves the
  # platforms disagree — BSD returns the instant an hour later, GNU refuses — so
  # this asserted whichever one it was written on and went red on the other in
  # CI. There is no correct answer here, only a consistent one: the first instant
  # after the time the vendor named, on the day they named.
  _src_limit
  local now want got
  now="$(_at America/New_York '2026-03-08 01:00:00')"
  want="$(_at America/New_York '2026-03-08 03:30:00')"
  got="$(limit_reset_epoch 'resets 2:30am (America/New_York)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: an ambiguous DST hour is NOT nudged forward" {
  # The sibling case, and the control for the one above: 2026-11-01 01:30 exists
  # TWICE in America/New_York. It is not a gap, so the fall-forward must not
  # fire — a rule that skipped an hour here would be an hour late every autumn.
  _src_limit
  local now got
  now="$(_at America/New_York '2026-11-01 00:30:00')"
  got="$(limit_reset_epoch 'resets 1:30am (America/New_York)' "$now")"
  [ "$got" = "$(_at America/New_York '2026-11-01 01:30:00')" ]
  [ "$(( got - now ))" -eq 3600 ]
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

# --- R1-P1-1: codex's zone suffix, when present, is authoritative -------------
# Round 1 put the codex "try again at H:MM AM/PM" branch FIRST and always read
# $TZ/etc/localtime, never checking for a zone suffix in the phrase at all — so
# an observer east or west of whichever zone the phrase actually named got a
# DIFFERENT (wrong) answer than the phrase's own zone would give. These three
# pin the fix: the verdict must be the SAME absolute instant no matter which
# side of the vendor's zone the observer is standing on.

@test "reset: codex zone suffix wins over an observer EAST of the vendor zone" {
  _src_limit
  local now want got
  now="$(_at UTC '2026-09-12 07:00:00')"
  want="$(_at Europe/Berlin '2026-09-12 18:00:00')"
  got="$(TZ=Asia/Tokyo limit_reset_epoch 'try again at 6:00 PM (Europe/Berlin)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: codex zone suffix wins over an observer WEST of the vendor zone" {
  _src_limit
  local now want got
  now="$(_at UTC '2026-09-12 07:00:00')"
  want="$(_at Europe/Berlin '2026-09-12 18:00:00')"
  got="$(TZ=America/Los_Angeles limit_reset_epoch 'try again at 6:00 PM (Europe/Berlin)' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: codex zone suffix across midnight resolves identically for any observer" {
  _src_limit
  local now want got_east got_west
  now="$(_at Europe/Berlin '2026-09-12 23:50:00')"
  want="$(_at Europe/Berlin '2026-09-13 00:10:00')"
  got_east="$(TZ=Asia/Tokyo limit_reset_epoch 'try again at 12:10 AM (Europe/Berlin)' "$now")"
  got_west="$(TZ=America/Los_Angeles limit_reset_epoch 'try again at 12:10 AM (Europe/Berlin)' "$now")"
  [ "$got_east" = "$want" ]
  [ "$got_west" = "$want" ]
}

@test "reset: codex with NO zone suffix falls back to the observer's own \$TZ (kills M8)" {
  # The control for the three above: when the phrase names no zone at all,
  # codex's documented behavior (limit.sh's own comment) is "renders in the
  # machine's local timezone" — so THIS case must still track $TZ. A mutant
  # that hardcodes the fallback to UTC passes every zone-suffix test above
  # (they never reach the fallback) but changes this one.
  _src_limit
  local now want got
  now="$(_at Asia/Tokyo '2026-09-12 08:00:00')"
  want="$(_at Asia/Tokyo '2026-09-12 18:00:00')"
  got="$(TZ=Asia/Tokyo limit_reset_epoch 'try again at 6:00 PM' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: codex's PM hour actually converts to 24h (kills the dropped +12 mutant)" {
  # A mutant that deletes the PM->+12 shift still often lands on "the future"
  # by accident (the undated rollover adds a day), which is how this survived
  # round 1's whole mutation run at 289/289 green. Assert the exact instant,
  # not just "still in the future", so a wrong-but-future answer fails too.
  _src_limit
  local now want got
  now="$(_at UTC '2026-09-12 08:00:00')"
  want="$(_at UTC '2026-09-12 18:00:00')"
  got="$(TZ=UTC limit_reset_epoch 'try again at 6:00 PM' "$now")"
  [ "$got" = "$want" ]
}

# --- R1-P2-2: codex's dated grammar (the one the docs actually record) --------

@test "reset: codex's dated 'Mon Dst, YYYY H:MM AM/PM' shape parses" {
  # limit.sh:281's own confirmed rollout quote and tests/bats/limit.bats:35/168's
  # dogfooded fixture use exactly this shape — round 1's codex regex required a
  # digit right after "try again at " and never matched it, so a codex limit
  # that ran past a day boundary (the ONLY case codex writes a date at all)
  # never expired (#75 unfixed for that shape).
  _src_limit
  local now want got
  now="$(_at UTC '2026-07-23 12:00:00')"
  want="$(_at UTC '2026-08-23 20:26:00')"
  got="$(TZ=UTC limit_reset_epoch 'try again at Aug 23rd, 2026 8:26 PM' "$now")"
  [ "$got" = "$want" ]
}

@test "reset: codex's dated shape still parses a year after the fact (was UNPARSEABLE)" {
  _src_limit
  local now want got
  now="$(_at UTC '2027-07-23 12:00:00')"
  want="$(_at UTC '2026-08-23 20:26:00')"
  got="$(TZ=UTC limit_reset_epoch 'try again at Aug 23rd, 2026 8:26 PM' "$now")"
  [ "$got" = "$want" ]
}
