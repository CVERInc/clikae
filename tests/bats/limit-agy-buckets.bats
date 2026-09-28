#!/usr/bin/env bats
# tests/bats/limit-agy-buckets.bats — #151: agy's 429 sentence names one of TWO
# resets (a 2-5 h rolling window, a ~143 h weekly bucket). limit_log_dry must
# not let a later window line erase an earlier weekly one, and
# limit_log_resetsv must keep each bucket's last phrase apart.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

_src_limit() {
  # shellcheck source=/dev/null
  . "$CLIKAE_TEST_ROOT/lib/core/limit.sh"
}

_two_bucket_log() {
  local f="$BATS_TEST_TMPDIR/cli.log"
  {
    printf '%s\n' 'E0927 stream_handler: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 143h31m50s.'
    printf '%s\n' 'E0927 stream_handler: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 2h44m36s.'
  } > "$f"
  printf '%s\n' "$f"
}

@test "limit_log_dry: a weekly wall followed by a window line reports the WEEKLY reset" {
  _src_limit
  local f; f="$(_two_bucket_log)"
  run limit_log_dry "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Resets in 143h31m50s" ] || false
}

@test "limit_log_resetsv: keeps each bucket's phrase apart" {
  _src_limit
  local f; f="$(_two_bucket_log)"
  limit_log_resetsv "$f"
  [ "$_LLR_WEEKLY" = "Resets in 143h31m50s" ] || false
  [ "$_LLR_WINDOW" = "Resets in 2h44m36s" ] || false
}

@test "limit_log_dry: a window-only log still reports its window reset" {
  _src_limit
  local f="$BATS_TEST_TMPDIR/cli.log"
  printf '%s\n' 'RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 4h10m0s.' \
                'RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 4h9m56s.' > "$f"
  run limit_log_dry "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Resets in 4h9m56s" ] || false
  limit_log_resetsv "$f"
  [ -z "$_LLR_WEEKLY" ] || false
}

@test "limit_reset_phrase_secs: sums units; 24h is still the window, 24h1s is weekly" {
  _src_limit
  run limit_reset_phrase_secs "Resets in 143h31m50s"
  [ "$output" = "516710" ] || false
  run limit_reset_phrase_secs "Resets in 1d2h"
  [ "$output" = "93600" ] || false
  run limit_reset_phrase_secs "Resets in soon"
  [ "$status" -ne 0 ]
  local f="$BATS_TEST_TMPDIR/cli.log"
  printf '%s\n' 'Individual quota reached. Resets in 24h0m0s.' > "$f"
  limit_log_resetsv "$f"
  [ "$_LLR_WINDOW" = "Resets in 24h0m0s" ] || false
  printf '%s\n' 'Individual quota reached. Resets in 24h0m1s.' > "$f"
  limit_log_resetsv "$f"
  [ "$_LLR_WEEKLY" = "Resets in 24h0m1s" ] || false
}

@test "limit_log_resetsv: a spaced '1d 2h' is read whole, so it is weekly (not truncated to 1d)" {
  _src_limit
  local f="$BATS_TEST_TMPDIR/cli.log"
  printf '%s\n' 'Individual quota reached. Resets in 1d 2h.' > "$f"
  limit_log_resetsv "$f"
  [ "$_LLR_WEEKLY" = "Resets in 1d 2h" ] || false
  [ -z "$_LLR_WINDOW" ] || false
}
