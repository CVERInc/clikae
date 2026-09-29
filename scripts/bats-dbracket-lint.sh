#!/usr/bin/env bash
# bats-dbracket-lint.sh — refuse a bare `[[ ... ]]` assertion line in a .bats file.
#
# WHY: on bash 3.2 (macOS /bin/bash, which `bats` runs under on a stock Mac)
# `set -e` does not fire on a failing `[[ ]]`. Bats relies on errexit, so a bare
# `[[ ]]` that fails anywhere but the LAST line of a test is silently ignored and
# the test reports `ok`. Proven 2026-09-29: an assertion with a deliberately
# wrong expected value stayed green on 3.2 until ` || false` was appended.
# The documented bats-core workaround is exactly that: `[[ ... ]] || false`.
#
# RULE: a line whose first token is `[[` (or `! [[`) must be joined to an OR/AND
# after its closing `]]` — either on the same line or, after a trailing `\`, on
# the next line. Heredoc bodies are skipped (fixture text, not assertions).
#
# Usage:  scripts/bats-dbracket-lint.sh [file.bats ...]   (default: every tracked *.bats)
# Exit:   0 clean, 1 at least one bare line (printed as file:line: text).
set -uo pipefail

if [ "$#" -eq 0 ]; then
  cd "$(dirname "$0")/.." || exit 1
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z '*.bats')
  [ "${#files[@]}" -gt 0 ] || { echo "bats-dbracket-lint: no .bats files found" >&2; exit 1; }
  set -- "${files[@]}"
fi

awk '
  FNR == 1 { if (pend != "") { print pend; bad = 1 } hd = ""; pend = "" }
  {
    line = $0
    if (hd != "") {                       # inside a heredoc body
      t = line; if (hdtab) sub(/^\t+/, "", t)
      if (t == hd) hd = ""
      next
    }
    s = line; sub(/^[ \t]+/, "", s)
    if (pend != "") {                     # previous line was `[[ ... ]] \`
      if (s !~ /^(\|\||&&)/) { print pend; bad = 1 }
      pend = ""
    }
    if (s ~ /^(! +)?\[\[/) {
      if (s ~ /\]\][ \t]*(\|\||&&)/) {
        # joined on the same line: fine
      } else if (s ~ /\\$/) {
        pend = FILENAME ":" FNR ": " s
      } else {
        print FILENAME ":" FNR ": " s; bad = 1
      }
    }
    h = line; gsub(/<<</, "", h)          # a here-string is not a heredoc
    if (match(h, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
      w = substr(h, RSTART, RLENGTH)
      hdtab = (w ~ /^<<-/)
      sub(/^<<-?[ \t]*["\047]?/, "", w)
      hd = w
    }
  }
  END { if (pend != "") { print pend; bad = 1 } exit bad }
' "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "bats-dbracket-lint: bare [[ ]] assertion(s) above never fail on bash 3.2 — append ' || false'" >&2
fi
exit "$rc"
