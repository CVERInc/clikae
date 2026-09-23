#!/usr/bin/env bash
# scripts/verify-agy-shapes.sh — does the agy adapter's model of agy still match agy?
#
# WHY A SCRIPT AND NOT A TEST. lib/adapters/antigravity.sh reads agy's own data
# with grep and sed: `"workspace"` out of `history.jsonl` to recover a session's
# directory, `"content"` out of a transcript to make a title. None of that is a
# documented interface. It is the internal file format of a vendor binary that
# **updates itself** — `agy update` is one of its own subcommands — so the shape
# can change without anything in this repo changing.
#
# tests/bats/antigravity.bats covers the same code against fixtures, and a
# fixture can only prove the parser matches MY model of the format. If agy
# renames a key tomorrow, every one of those tests still passes. This script is
# the other half: run the same extraction against the REAL files agy wrote on
# this machine.
#
# Read-only. It opens agy's data and nothing else — no launch, no login, no
# network, and it never writes.
#
# 🔴 THREE STATES, NOT TWO. No agy data on this machine (CI, a fresh install,
# a tank that has never run) is `skip`, never a pass — the failure being guarded
# against is a green light that means "I did not look".
#
# Verified 2026-08-16 against agy 1.1.13: workspace present on 646/646 history
# lines across 3 tanks, content present in transcripts, and adapter_title_for_file
# returned a real title.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0; skip=0
ok() { printf '  \033[32m✅ PASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no() { printf '  \033[31m🔴 FAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
sk() { printf '  \033[33m—  skip\033[0m  %s\n' "$*"; skip=$((skip+1)); }

printf '\n\033[1mverify-agy-shapes\033[0m — the adapter'"'"'s assumptions, against real agy data\n\n'

command -v agy >/dev/null 2>&1 \
  && printf '  agy on PATH: %s\n\n' "$(agy --version 2>/dev/null | head -1)" \
  || printf '  agy is not on PATH (checking its data anyway)\n\n'

root="${CLIKAE_HOME:-$HOME/.clikae}/profiles/antigravity"
if [ ! -d "$root" ]; then
  sk "no agy tanks under $root"
else
  # ── 1. history.jsonl carries "workspace" ────────────────────────────────────
  # adapter_session_cwd greps this to recover which directory a session ran in.
  # Assert the RATE, not merely presence: one surviving line would satisfy a
  # `grep -q` while the feature was broken for every other session.
  #
  # 🔴 EVERY tank, not `head -1`. The first draft took whichever file find
  # returned first and reported "2/2" — a tank with two lines — while the tank
  # with 637 sat unexamined. A sample I picked is an upper bound, not an
  # estimate; if the whole population is cheap to read, read it.
  total=0; have=0; files=0
  while IFS= read -r hist; do
    [ -n "$hist" ] || continue
    files=$((files+1))
    total=$((total + $(wc -l < "$hist" | tr -d ' ')))
    # 🔴 no `|| echo 0` here. grep -c PRINTS 0 and EXITS 1 when nothing matches,
    # so the fallback fires too and the substitution yields "0\n0" — an
    # arithmetic syntax error that killed this script mid-run while it still
    # exited 0. Which is the "green light that means I did not look" its own
    # header warns about, happening to the header.
    c="$(grep -c '"workspace"' "$hist" 2>/dev/null)"; c="${c:-0}"
    have=$((have + c))
  done < <(find "$root" -name history.jsonl -type f 2>/dev/null)
  if [ "$files" -eq 0 ]; then
    sk 'no history.jsonl yet (no agy session has run in any tank)'
  elif [ "$total" -eq 0 ]; then
    sk "history.jsonl exists but is empty ($files file(s))"
  elif [ "$have" = "$total" ]; then
    ok "\"workspace\" on $have/$total history lines across $files tank(s)"
  elif [ "$have" -gt 0 ]; then
    no "\"workspace\" on only $have/$total history lines — the format is drifting"
  else
    no "\"workspace\" is gone from history.jsonl — adapter_session_cwd returns nothing"
  fi

  # ── 2. a transcript carries "content" ───────────────────────────────────────
  # adapter_session_title greps the first line of a transcript for it.
  tr_="$(find "$root" -path '*/logs/transcript.jsonl' -type f 2>/dev/null | head -1)"
  if [ -z "$tr_" ]; then
    sk 'no transcript.jsonl yet (titles are untested on real data)'
  elif head -n 1 "$tr_" | grep -q '"content"'; then
    ok '"content" present on a real transcript'\''s first line'
  else
    no '"content" is not on the first transcript line — titles will come out blank'
  fi

  # ── 3. the adapter'\''s OWN function, on the real file ────────────────────────
  # Checks 1 and 2 assert the ingredients. This runs the code, because a shape
  # can be present and the extraction still wrong (an escaped quote, a nested
  # object, a key that moved one level down).
  if [ -z "${tr_:-}" ]; then
    sk 'no transcript to run adapter_title_for_file against'
  elif [ ! -f lib/adapters/antigravity.sh ]; then
    sk 'lib/adapters/antigravity.sh not found from here'
  else
    # adapter_title_for_file is the one that takes a PATH; adapter_session_title
    # takes (dir, sid) and builds the path itself. The first draft called the
    # wrong one, got an empty string, and reported a FAIL against working code —
    # a broken ruler reads exactly like a broken subject.
    title="$(
      # shellcheck source=/dev/null
      . lib/adapters/antigravity.sh 2>/dev/null
      declare -F adapter_title_for_file >/dev/null 2>&1 || { printf '__NO_FN__'; exit 0; }
      adapter_title_for_file "$tr_" 2>/dev/null
    )"
    case "$title" in
      __NO_FN__) sk 'adapter_title_for_file is not defined (renamed?)' ;;
      '')        no 'adapter_title_for_file returned EMPTY on a real transcript' ;;
      *)         ok "title extracted from real data: $(printf '%.44s' "$title")…" ;;
    esac
  fi
fi

printf '\n  \033[1m%d pass, %d fail, %d skip\033[0m\n' "$pass" "$fail" "$skip"
printf '  \033[2mskip is not a pass — it is a question this run could not ask.\033[0m\n\n'

# A run that asked NOTHING is not a pass either. This script died mid-way once
# and still exited 0; every individual check was fine, and the total was the
# only thing that could have said so.
if [ $((pass + fail + skip)) -eq 0 ]; then
  printf '  \033[31m🔴 this run performed no checks at all — the script itself is broken.\033[0m\n\n'
  exit 2
fi
[ "$fail" -eq 0 ]
