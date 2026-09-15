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

# #61 round-5 merge: lib/commands/cockpit.sh:428's comment ("the FIRST tank
# `list_all_profiles`' `| sort` puts in front of a real cockpit tank") states
# an ORDERING guarantee that nothing asserted — and the marker rewrite moved
# the walk and added a process-level cache in front of it. Both paths (cold
# walk and warmed cache) must still come out sorted.
@test "enumerator order: list_all_profiles is sorted, cold and cache-warmed (cockpit.sh --off depends on it)" {
  mkdir -p "$CLIKAE_HOME/profiles/claude/mid" "$CLIKAE_HOME/profiles/claude/aaa" \
           "$CLIKAE_HOME/profiles/claude/zzz" "$CLIKAE_HOME/profiles/codex/bbb"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/mid/.clikae-tank"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/aaa/.clikae-tank"
  printf 'claude\n' > "$CLIKAE_HOME/profiles/claude/zzz/.clikae-tank"
  printf 'codex\n'  > "$CLIKAE_HOME/profiles/codex/bbb/.clikae-tank"
  run bash -c '
    set -eo pipefail
    CLIKAE_ROOT="'"$CLIKAE_TEST_ROOT"'"; CLIKAE_LIB="$CLIKAE_ROOT/lib"
    source "$CLIKAE_LIB/core/adapter_loader.sh"
    source "$CLIKAE_LIB/core/profile_store.sh"
    cold="$(list_all_profiles)"
    profiles_cache_warm
    warm="$(list_all_profiles)"
    [ "$cold" = "$(printf "%s\n" "$cold" | sort)" ] || { echo "COLD UNSORTED: $cold"; exit 1; }
    [ "$warm" = "$cold" ] || { echo "WARM DIFFERS: $warm"; exit 1; }
    printf "%s\n" "$cold" | cut -f1,2 | tr "\t" "/" | tr "\n" " "
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "claude/aaa claude/mid claude/zzz codex/bbb " ] || { echo "order=[$output]"; false; }
}
