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

# json_string_leaves <file>  -> one `<path><TAB><value>` line per STRING-valued
# member of the JSON in <file>, where <path> is the member's keys from the
# root joined by `US` (\037): `model` is a top-level "model", and
# `modelSettings<US><name><US>effortLevel` is that nested one. This is what
# json_value_for_key cannot say — it matches a key at any depth, and a settings
# file may repeat a key name under another object (#237: Claude's
# `effortLevel` is both a top-level key and a per-model one).
# A character walk in awk (no jq/python): a string is consumed as a string, so
# a brace or a colon inside a value moves nothing. Anything inside an array is
# not reported (it has no key path). \" and \\ are unescaped; other escapes
# are left as written. Prints nothing for a missing or unreadable file; never
# aborts the caller.
json_string_leaves() {
  [ -f "$1" ] || return 0
  awk '
    { text = text $0 "\n" }
    END {
      n = length(text); depth = 0; pending = ""; havepending = 0; wantvalue = 0
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (c == "\"") {
          s = ""
          for (i++; i <= n; i++) {
            c = substr(text, i, 1)
            if (c == "\\") { i++; d = substr(text, i, 1); s = s ((d == "\"" || d == "\\") ? d : "\\" d); continue }
            if (c == "\"") break
            s = s c
          }
          if (depth < 1 || inarr[depth] || skip[depth]) continue
          if (wantvalue) {
            path = ""
            for (j = 1; j < depth; j++) path = path keys[j] "\037"
            print path keys[depth] "\t" s
            wantvalue = 0
          } else { pending = s; havepending = 1 }
          continue
        }
        if (c == ":") { if (havepending) { keys[depth] = pending; wantvalue = 1 } havepending = 0; continue }
        if (c == "{" || c == "[") {
          depth++
          inarr[depth] = (c == "[")
          skip[depth] = (depth > 1 && (skip[depth - 1] || inarr[depth - 1]))
          wantvalue = 0; havepending = 0; continue
        }
        if (c == "}" || c == "]") { if (depth > 0) depth--; wantvalue = 0; havepending = 0; continue }
        if (c == ",") { wantvalue = 0; havepending = 0 }
      }
    }' "$1" 2>/dev/null || true
  return 0
}
