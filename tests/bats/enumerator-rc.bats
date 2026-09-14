#!/usr/bin/env bats
# tests/bats/enumerator-rc.bats — #61 round-3 P1-1: `list_all_profiles`'s own
# exit status must never depend on whether the LAST candidate directory it
# walks happens to be a tank.
#
# `_list_all_profiles_uncached`'s inner loop body used to be
# `tank_dir_is_tank … && printf …` — under `bin/clikae`'s `set -eo pipefail`,
# a `while` loop's exit status is its LAST command's, so a non-tank sorting
# last made the whole `while` (and therefore the `for`, and the `… | sort`
# pipeline) return 1, even though stdout was completely correct. `doctor`,
# `status`, `home`'s board (bare `clikae`), and `info` all call straight into
# this under `set -e` and died silently — zero lines, rc 1 — the moment a
# stray directory happened to sort after every real tank.
#
# `claude/zzstray` is chosen to sort after every other name in this store
# (single engine, single real tank `ok`) so it is unambiguously the LAST
# candidate `_tank_candidates`/the outer engine loop visits — bash's own
# pathname expansion is locale-sorted, so this is deterministic, not
# order-of-readdir luck.

load '../helpers'

_seed_trailing_non_tank_store() {
  mkdir -p "$CLIKAE_HOME/profiles/claude/ok"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/ok/.clikae-tank"
  # Not a tank: no marker. Name sorts after "ok" so it is the LAST candidate
  # under the only (and therefore also last) engine directory.
  mkdir -p "$CLIKAE_HOME/profiles/claude/zzstray"
}

@test "enumerator rc #61 P1-1: doctor exits 0 with output when the trailing candidate is not a tank" {
  _seed_trailing_non_tank_store
  run clikae doctor
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -n "$output" ] || false
  [ "${#lines[@]}" -gt 0 ] || false
}

@test "enumerator rc #61 P1-1: status exits 0 with output when the trailing candidate is not a tank" {
  _seed_trailing_non_tank_store
  run clikae status
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -n "$output" ] || false
  [ "${#lines[@]}" -gt 0 ] || false
}

@test "enumerator rc #61 P1-1: info exits 0 with output when the trailing candidate is not a tank" {
  _seed_trailing_non_tank_store
  run clikae info
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -n "$output" ] || false
  [ "${#lines[@]}" -gt 0 ] || false
}

@test "enumerator rc #61 P1-1: bare board exits 0 with output when the trailing candidate is not a tank" {
  _seed_trailing_non_tank_store
  run clikae
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [ -n "$output" ] || false
  [ "${#lines[@]}" -gt 0 ] || false
}

@test "enumerator rc #61 P1-1: list_all_profiles itself returns 0 regardless of trailing candidate order" {
  _seed_trailing_non_tank_store
  run clikae tanks
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
  [[ "$output" == *"ok"* ]] || false
  [[ "$output" != *"zzstray"* ]] || false
}
