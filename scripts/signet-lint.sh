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
#
# THE REF IS PINNED. Fetching a neighbour's HEAD would let their commit turn this
# repo's CI red — a gate whose colour somebody else sets. Bumping SIGNET_REF is
# how clikae says "we conform to that version", which makes drift news instead of
# a surprise.
set -uo pipefail

SIGNET_REF="${SIGNET_REF:-18d380bfcb6d3e5bc89e302f7f9ecf7adffc8c7a}"
LINT=""

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
