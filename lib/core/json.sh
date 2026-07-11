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
