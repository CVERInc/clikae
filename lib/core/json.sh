# shellcheck shell=bash
# lib/core/json.sh — minimal JSON string helpers (no jq dependency).
#
# Shared by commands that offer a `--json` mode (status, list) so their
# machine-readable output escapes identically. bash 3.2 ${//} substitution;
# the values we emit (cli/profile names, emails, paths, env values) are
# single-line, but we escape control chars defensively anyway.

# json_str <value>  -> a JSON string literal (quoted, escaped) for <value>.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"     # backslash first, or it double-escapes the others
  s="${s//\"/\\\"}"     # double quote
  s="${s//$'\t'/\\t}"   # tab
  s="${s//$'\n'/\\n}"   # newline
  s="${s//$'\r'/\\r}"   # carriage return — a CRLF-tainted value (pasted email,
                        # Windows-written config) must not emit invalid JSON
  s="${s//$'\b'/\\b}"   # backspace / form feed: same defensive tier
  s="${s//$'\f'/\\f}"
  printf '"%s"' "$s"
}

# json_or_null <value>  -> json_str(<value>), or the literal `null` if empty.
json_or_null() { [ -n "$1" ] && json_str "$1" || printf 'null'; }

# json_value_for_key <file> <key-regex>  -> the value(s) for every "<key>":
# "value" pair in <file> whose key matches <key-regex> (an ERE, already
# escaped by the caller if the key itself isn't a literal pattern), one per
# line, in file order. Escape-aware (a value containing \" is not truncated
# mid-string) and, critically, ANCHORED to the matched pair — grep -oE
# isolates just the "<key>":"<value>" text before sed ever sees it, so a
# compact/single-line JSON body with several keys can't have a naive `.*:`
# walk PAST the matched pair to the LAST value in the whole file (#74 round-1
# P1-4: lib/adapters/antigravity.sh's cache lookup did exactly that — every
# real agy install writes this file compact/single-line, so any cache with
# more than one entry silently returned a DIFFERENT project's session).
# Prints one match per line if the key repeats (e.g. a naively
# appended-not-merged JSON body); `| tail -n 1` for callers that want the
# LAST — antigravity.sh's cache lookup does, since a repeated key there means
# a newer write appended rather than merged, and the last one is the current
# value. Never aborts the caller under `set -eo pipefail`.
json_value_for_key() {
  local f="$1" key="$2" re
  [ -f "$f" ] || return 0
  re="\"$key\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\""
  grep -oE "$re" "$f" 2>/dev/null \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//' || true
  return 0
}
