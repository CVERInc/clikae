#!/usr/bin/env bash
# scripts/mutate.sh — break a guard on purpose and prove a test notices.
#
# NOT part of scripts/test.sh. This is a manual audit: it copies the repo once
# per mutation and runs a bats file against the copy, so it costs minutes, not
# seconds. Run it when you add a guard you care about, or when you want to know
# whether the ones already there are real.
#
# WHY. A passing suite tells you the code is green on the inputs someone thought
# to write. It does not tell you a guard exists — a test can assert the shape of
# an outcome the code reaches for some other reason, or (measured, 2026-08-16)
# never call the function it names at all. The only evidence that a guard is
# load-bearing is watching the suite go red when you remove it.
#
# The four rows below are docs/memory.md §4's locked values, the promises clikae
# makes about the human's data. All four fire.
#
# ── Two traps this harness exists to avoid ──────────────────────────────────
#
# 🔴 A mutation that did not apply looks exactly like a guard that works.
#    First run of this audit reported three hollow guards. All three were the
#    ruler: `tank_is_solo` lives in profile_store.sh, not tank.sh; notice.sh's
#    function is `carry_notice_once`, not the name I guessed. Nothing was
#    mutated and the tests were green for the most boring reason there is. So
#    every row now checksums the target before and after, and a mutation that
#    changed nothing reports ⛔ — it is not a result in either direction.
#
# 🔴 Use `!` as the s/// delimiter, never `{}`. Perl requires balanced braces
#    inside brace-delimited s{}{}, and a shell function's replacement text
#    almost always has an unmatched `{`. Perl then dies of a syntax error, the
#    file is untouched, and you get the trap above.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
pass=0; hollow=0; broken=0

# run_one <label> <bats file> <mutated path> <command…>
run_one() {
  local name="$1" file="$2" target="$3"; shift 3
  local R; R="$(mktemp -d)" || return 1
  ( cd "$SRC" && tar cf - lib bin docs scripts tests AGENTS.md README.md ) \
    | ( cd "$R" && tar xf - )

  local before after
  before="$(cksum < "$R/$target")"
  ( cd "$R" && "$@" ) >/dev/null 2>&1
  after="$(cksum < "$R/$target")"
  if [ "$before" = "$after" ]; then
    printf '  ⛔ %-42s mutation never applied to %s\n' "$name" "$target"
    broken=$((broken + 1)); rm -rf "$R"; return
  fi

  local out rc
  out="$(cd "$R" && bats "tests/bats/$file" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  ✅ %-42s guard broken → suite red\n' "$name"
    printf '%s' "$out" | grep '^not ok' | head -2 | sed 's/^/       /'
    pass=$((pass + 1))
  else
    printf '  🔴 %-42s guard broken, suite still GREEN\n' "$name"
    hollow=$((hollow + 1))
  fi
  rm -rf "$R"
}

echo "mutating docs/memory.md §4's locked values:"

# "A machine that never opted in shares nothing, ever."
run_one "opt-in: share without opting in" memory.bats lib/core/soul.sh \
  perl -0pi -e 's!(\[ -f "\$f" \] \|\| return 0\n  tr -d)!\[ -f "$f" \] || { echo fleet; return 0; }\n  tr -d!s' lib/core/soul.sh

# "A solo tank is walled out of the fleet by design."
run_one "solo: a solo tank stops being solo" memory.bats lib/core/profile_store.sh \
  perl -pi -e 's!^tank_is_solo\(\) .*$!tank_is_solo() { return 1; }!' lib/core/profile_store.sh

# "Crossing to a DIFFERENT account is announced and never silent."
run_one "cross-account note: never shown" notice.bats lib/core/notice.sh \
  perl -pi -e 's!^carry_notice_once\(\) \{$!carry_notice_once() { return 0; } _dead_carry_notice_once() {!' lib/core/notice.sh

# "Aggregate, never mutate the source. Seed by copy."
run_one "share: copy becomes move" memory.bats lib/commands/memory.sh \
  perl -pi -e 's!\bcp -R\b!mv!g' lib/commands/memory.sh

printf '\n%d guard(s) proven, %d hollow, %d mutation(s) that never applied\n' \
  "$pass" "$hollow" "$broken"
[ "$hollow" -eq 0 ] && [ "$broken" -eq 0 ]
