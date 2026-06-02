# shellcheck shell=bash
# lib/core/history.sh — the "what clikae did" log. Every time a session is carried
# onward (clikae to / relay / handoff, and later the supervisor's auto-switch), one
# line is appended here. `clikae status` shows the recent tail, so even when a
# carry happened while you were away you can see what moved where.
#
# Format, one event per line:  <iso-8601>␟<event text>
# Plain append-only text under $CLIKAE_HOME; safe to delete or tail by hand.

history_file() { printf '%s\n' "$CLIKAE_HOME/history"; }

# history_log <event text> — append a timestamped line. Never fails the caller
# (best-effort): a carry must still happen even if the log isn't writable.
history_log() {
  local ev="$1" ts f
  [ -n "$ev" ] || return 0
  ts="$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo '?')"
  f="$(history_file)"
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\037%s\n' "$ts" "$ev" >> "$f" 2>/dev/null || true
  return 0
}

# history_recent [n] — echo the last n events (default 5), oldest-first, formatted
# "<iso>  <event>". Nothing if there's no log yet.
history_recent() {
  local n="${1:-5}" f
  f="$(history_file)"
  [ -f "$f" ] || return 0
  tail -n "$n" "$f" 2>/dev/null | while IFS=$'\037' read -r ts ev; do
    [ -n "$ev" ] || continue
    printf '%s  %s\n' "$ts" "$ev"
  done
}
