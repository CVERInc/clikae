#!/usr/bin/env bash
# signet-lint.sh — run CVER's CLI design-system lint over clikae's surface.
#
# signet (github.com/CVERInc/signet) is the design system for the plain-text CLI
# surface across the family. Its lint is doc-and-CI only and never a runtime
# dependency: clikae sells "one file you run, no dependencies", and a shared
# library would break that promise. So this fetches the linter, uses it, and
# leaves nothing behind.
#
# Usage:  scripts/signet-lint.sh [--offline <path-to-lint.sh>]
#         scripts/signet-lint.sh --self-test
#
# THE REF IS PINNED. Fetching a neighbour's HEAD would let their commit turn this
# repo's CI red — a gate whose colour somebody else sets. Bumping SIGNET_REF is
# how clikae says "we conform to that version", which makes drift news instead of
# a surprise.
set -uo pipefail

SIGNET_REF="${SIGNET_REF:-18d380bfcb6d3e5bc89e302f7f9ecf7adffc8c7a}"
LINT=""

# --self-test proves the LOCAL clock-glyph scan below still fires — no
# network, no upstream linter, nothing else this script does. See that
# scan's own header for why it exists at all (2026-09-22: `⏳` breached the
# standing no-emoji rule and neither this wrapper's own ranges nor the
# fetched linter's ever covered the block it lives in).
if [ "${1:-}" = --self-test ]; then
  probe="$(mktemp "${TMPDIR:-/tmp}/signet-lint-selftest.XXXXXX")"
  trap 'rm -f "$probe"' EXIT
  printf '#!/usr/bin/env bash\n# ⏳ token expired\n' > "$probe"
  # -0777 slurps the whole file as one string before matching — this probe is
  # two lines and the bare glyph is on line 2, so a per-line -ne would exit
  # on line 1's non-match before ever reaching it.
  if perl -CSD -0777 -ne 'exit(/[\x{231A}-\x{231B}\x{23E9}-\x{23FA}]/ ? 0 : 1)' "$probe"; then
    echo "signet-lint --self-test: a file containing ⏳ is caught (clock-glyph scan)"
    exit 0
  fi
  echo "signet-lint --self-test: ⏳ slipped past the clock-glyph scan — not trusting this ruler" >&2
  exit 1
fi

case "${1:-}" in
  --offline) LINT="${2:-}" ;;
esac

cd "$(dirname "$0")/.." || exit 2

if [ -z "$LINT" ]; then
  LINT="$(mktemp "${TMPDIR:-/tmp}/signet-lint.XXXXXX")"
  url="https://raw.githubusercontent.com/CVERInc/signet/${SIGNET_REF}/packages/cli/lint.sh"
  curl -fsSL "$url" -o "$LINT" || { echo "signet-lint: could not fetch $url" >&2; exit 2; }
fi
[ -s "$LINT" ] || { echo "signet-lint: no linter at $LINT" >&2; exit 2; }

# Prove the ruler still works before trusting a clean run from it. A linter that
# quietly stopped checking reads exactly like a tidy repo — and this one is
# fetched over the network, so "did it arrive intact" is a real question.
bash "$LINT" --self-test >/dev/null 2>&1 || {
  echo "signet-lint: the linter failed its own self-test — not trusting its verdict" >&2
  exit 2
}

files=(bin/clikae)
while IFS= read -r f; do files+=("$f"); done < <(find lib -name '*.sh' | sort)

raw="$(bash "$LINT" "${files[@]}" 2>&1)"

# ---- the gap the fetched linter's own ranges leave (2026-09-22) -------------
#
# `⏳` (U+23F3) reached the tmux status row and stayed there — the standing
# no-emoji rule breached, silently, because the ranges signet's own scan (and
# this wrapper's cursor-exception check just below) cover — U+2600–27BF,
# U+1F300–1FAFF, U+2B00–2BFF, U+FE0F — never touched Miscellaneous Technical
# (U+2300–23FF) at all. That block also holds `⌘` (U+2318) and `⌥` (U+2325),
# which ARE legitimate key names clikae prints on purpose, so the fix is not
# "ban the block" — it is naming the SUBSET that is actually
# emoji-presentation: U+231A–231B (⌚⌛) and U+23E9–23FA (⏩⏪⏫⏬⏭⏮⏯⏰⏱⏲⏳⏴⏵⏶⏷⏸⏹⏺),
# which excludes both key names by a wide margin. This is scanned locally,
# over the same file list, rather than widening $SIGNET_REF: the fetched
# linter is a neighbour's ref, pinned on purpose (see this file's own header),
# and clikae cannot silently widen what someone else's commit scans for.
clockraw=""
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    clockraw="${clockraw}${hit}
"
  done < <(perl -CSD -ne 'print "$ARGV:$.: [emoji-clock] $_" if /[\x{231A}-\x{231B}\x{23E9}-\x{23FA}]/' "$f" 2>/dev/null)
done
raw="${raw}
${clockraw}"

# ---- the one accepted exception, named rather than hidden -------------------
#
# `❯` is the selection CURSOR on the board, the resume picker, the clean list and
# the relay menu. The linter flags it because U+276F happens to fall inside the
# emoji block it scans, not because anyone decided the mark was wrong: signet's
# roles table has a `selection mark` of `[x]` / `[ ]`, which is a CHECKBOX — "this
# one is chosen" — and a cursor answers a different question, "you are here".
# A row can be under the cursor without being chosen, so the two are not the same
# job, and signet's own first ruler is that a mark earns its place by doing a job
# no other mark does.
#
# Reported upstream; the fix belongs in signet's table, not in clikae's muscle
# memory ("Change the look, never the keys" — SPEC.md). Until that lands, these
# are filtered by MATCHING THE CURSOR ITSELF rather than by file and line, so the
# exception cannot silently widen: any other printed emoji, anywhere, still fails.
kept=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *': [emoji]'*)
      f="${line%%:*}"; rest="${line#*:}"; n="${rest%%:*}"
      # Skip ONLY when the cursor is the whole reason. Testing "does the line
      # contain ❯" would let a second glyph ride along on the same line, which is
      # how a named exception quietly becomes a general one: strip the cursors
      # first, then ask whether anything in the scanned ranges is left.
      if [ -f "$f" ] && [ -n "$n" ] \
         && ! sed -n "${n}p" "$f" 2>/dev/null \
            | perl -CSD -pe 's/\x{276F}//g' \
            | perl -CSD -ne 'exit(/[\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}\x{2B00}-\x{2BFF}\x{FE0F}]/ ? 0 : 1)'; then
        continue
      fi ;;
    'signet-cli-lint: '*) continue ;;   # the linter's own tally
  esac
  kept="${kept}${line}
"
done <<EOF
$raw
EOF

kept="$(printf '%s' "$kept" | sed '/^$/d')"
if [ -n "$kept" ]; then
  printf '%s\n' "$kept" >&2
  printf 'signet-lint: %s violation(s)\n' "$(printf '%s\n' "$kept" | grep -c .)" >&2
  exit 1
fi
echo "signet-lint: clean (cursor exception: $(printf '%s\n' "$raw" | grep -c ': \[emoji\]') known ❯ line(s))"
exit 0
