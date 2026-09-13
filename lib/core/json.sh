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

# json_field_str <json> <field>  ->  the DECODED string value of "<field>":"…"
# found anywhere in <json>, or return 1 (nothing echoed) if <field> is absent,
# not a string, or <json> doesn't contain a well-formed "field":"value" pair.
#
# Purpose-built, like lib/core/burn_status.sh's burn_status_field: the only
# JSON this is asked to read is a hook payload (PreToolUse's stdin object —
# lib/hooks/cockpit-guard.sh, #63) where every field name it looks up
# (tool_name, and tool_input's model/prompt) is unique across the whole
# object, so a flat scan finds the right pair without walking into nested
# objects on purpose. NOT a general JSON parser: a field name that repeats
# at two different nesting levels would find whichever occurs first.
#
# The match handles escaped quotes/backslashes inside the value (`\"`, `\\`)
# so a value containing a literal `"` doesn't truncate the extraction early —
# an agent prompt routinely contains quoted text. Decodes `\"` `\\` `\n` `\t`
# `\r`; everything else survives as the literal two-character escape (this is
# a keyword-matching input, not a display value, and none of the keywords it
# is matched against contain a backslash).
json_field_str() {
  local json="$1" field="$2" raw esc
  # `[[:space:]]*` around the colon: JSON permits whitespace there (pretty-
  # printed output, or a hand-edited fixture) and the old pattern (`"field":"`
  # with zero tolerance) went silently blind on anything but compact JSON —
  # no match, rc=1, indistinguishable from the field being absent (#63 P1-1).
  raw="$(printf '%s' "$json" | grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\"" | head -n 1)"
  [ -n "$raw" ] || return 1
  raw="${raw#*:}"            # drop `"field"[[:space:]]*:`
  raw="${raw#"${raw%%[![:space:]]*}"}"   # drop any whitespace left after the colon
  raw="${raw#\"}"; raw="${raw%\"}"   # drop the surrounding quotes
  esc=$'\001'                # placeholder: protects real backslashes while
                              # the two-char escapes below are decoded, so
                              # `\\n` (backslash, n) doesn't get read as `\n`
                              # (an escaped newline) — order matters here.
  raw="${raw//\\\\/$esc}"
  raw="${raw//\\\"/\"}"
  raw="${raw//\\n/$'\n'}"
  raw="${raw//\\t/$'\t'}"
  raw="${raw//\\r/$'\r'}"
  raw="${raw//$esc/\\}"
  printf '%s' "$raw"
}
