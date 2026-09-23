# shellcheck shell=bash
# lib/core/compact.sh — warm /compact before the prompt cache goes cold (#131).
#
# WHY. On a Claude subscription the main conversation's prompt cache lives one
# hour. A cockpit that sits idle past that and then speaks again re-reads its
# whole context at fresh-input price and re-writes the cache — for a large
# conversation that is two orders of magnitude more than the same turn warm
# (docs/fleet-cost-doctrine.md). Compacting WHILE the cache is still warm only
# reads the cache and generates a summary; the next turn rebuilds the cache on
# the summary alone.
#
# WHAT. The per-session watcher (wake_watch, lib/core/wake.sh — the window that
# already lives in every clikae tmux session) calls compact_tick once a minute.
# It types `/compact` into the engine pane ONCE when ALL of these hold:
#
#   1. the preference allows it           (compact_enabled — ON by default,
#                                           asked once at launch, per-tank off)
#   2. the session's transcript is known  (the id clikae stamped at launch —
#                                           never a guess at "latest in cwd")
#   3. nothing has been written to that transcript for COMPACT_IDLE_SECONDS
#                                          (50 min: under the 1h TTL, with a
#                                           watcher tick and a settle to spare)
#   4. the context is at least COMPACT_MIN_TOKENS, read from the transcript's
#      last real `usage` (compact_context_tokens)
#   5. the pane is alive and its screen has stopped moving (wake_pane_idle —
#      the same mechanism check the waiter uses, so no turn is running)
#   6. the prompt line is EMPTY (compact_prompt_line_empty) — never while
#      someone is typing.
#
# 🔴 NEVER ON A CLOCK ALONE. (3) is "the conversation has been quiet", read from
# the conversation's own file, not "it is 50 minutes past something". There is
# no scheduled /clear and no timer that fires without all six answers.
#
# 🔴 ONCE PER IDLE PERIOD. The idle period is identified by the transcript's
# mtime at the moment of the send. The compaction itself writes to the
# transcript, so the next idle period has a different mtime — and by then the
# context is the summary, well under the threshold. A send that did not take
# (the engine ignored it) is not retried inside the same period.
#
# EVERY ACTION IS WRITTEN DOWN, in the waiter's own trace (wake_trace, one file
# per tank under state/wake/), so `clikae watch compact` and `clikae wake` can
# say what happened while nobody was looking:
#
#   compact-sent      context=<N> idle=<s>  — the moment it typed /compact
#   compact-verified  before=<N> after_cache_creation=<M> after_context=<K>
#
# The second line is the issue's own verification: the first turn after a warm
# compact should show `cache_creation_input_tokens` near the summary's size
# (tens of K), not the full context. Recording both numbers lets a person check
# that against the bill instead of taking this file's word for it.

# Below the 1h TTL by ten minutes: the watcher looks once a minute and the
# settle check spends a few seconds more, so this still lands well inside it.
COMPACT_IDLE_SECONDS=3000

# Below this, a cold re-read costs too little to be worth a summary that loses
# detail. Override with $CLIKAE_COMPACT_MIN_TOKENS.
COMPACT_MIN_TOKENS=200000

COMPACT_COMMAND="/compact"

# Per-watcher memory (one watcher per session, so plain globals suffice).
_COMPACT_SENT_MTIME=""     # transcript mtime at the last send — the idle period
_COMPACT_PENDING_FILE=""   # transcript awaiting its after-numbers
_COMPACT_PENDING_OFFSET=0  # its byte size at the send
_COMPACT_PENDING_BEFORE=0  # the context we compacted

# --- the preference -----------------------------------------------------------
#
# One file, $CLIKAE_HOME/warm-compact. Its first bare `on` / `off` line is the
# global answer; `off <engine>/<tank>` lines opt single tanks out. A missing or
# unanswered file means ON: the maintainer's ruling is on-by-default, with the
# one-time question at launch (compact_ask_once) recording an explicit answer.
# Like wake-on-reset, this is what the human WANTS, never a record of state.

compact_pref_file() { printf '%s\n' "$CLIKAE_HOME/warm-compact"; }

# compact_pref_get -> on | off | unset
compact_pref_get() {
  local f v=""
  f="$(compact_pref_file)"
  [ -f "$f" ] && v="$(grep -E '^[[:space:]]*(on|off)[[:space:]]*$' "$f" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  case "$v" in on|off) printf '%s' "$v" ;; *) printf 'unset' ;; esac
}

# compact_tank_off <engine> <tank> -> 0 when that tank is opted out.
compact_tank_off() {
  local f; f="$(compact_pref_file)"
  [ -f "$f" ] || return 1
  grep -qxF "off $1/$2" "$f" 2>/dev/null
}

# compact_pref_set <on|off> [<engine> <tank>] -> persist the global answer, or
# (with a tank) add/remove that tank's opt-out line. Returns 1 on a bad value.
compact_pref_set() {
  local val="$1" engine="${2:-}" tank="${3:-}" f rest
  case "$val" in on|off) : ;; *) return 1 ;; esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  f="$(compact_pref_file)"
  rest=""
  [ -f "$f" ] && rest="$(cat "$f" 2>/dev/null)"
  if [ -n "$engine" ] && [ -n "$tank" ]; then
    rest="$(printf '%s\n' "$rest" | grep -vxF "off $engine/$tank" | grep -v '^$' || true)"
    [ "$val" = "off" ] && rest="$rest${rest:+$'\n'}off $engine/$tank"
  else
    rest="$(printf '%s\n' "$rest" | grep -vE '^[[:space:]]*(on|off)[[:space:]]*$' | grep -v '^$' || true)"
    rest="$val${rest:+$'\n'}$rest"
  fi
  printf '%s\n' "$rest" > "$f" 2>/dev/null || true
}

# compact_enabled <engine> <tank> -> 0 when this tank may be warm-compacted.
# $CLIKAE_WARM_COMPACT (on/off) is a one-run override, never persisted.
compact_enabled() {
  local engine="${1:-}" tank="${2:-}"
  case "${CLIKAE_WARM_COMPACT:-}" in
    on)  return 0 ;;
    off) return 1 ;;
  esac
  [ "$(compact_pref_get)" = "off" ] && return 1
  if [ -n "$engine" ] && [ -n "$tank" ] && compact_tank_off "$engine" "$tank"; then
    return 1
  fi
  return 0
}

# compact_ask_once <engine> <tank> -> settle the global preference, once, at
# launch — the same moment and the same reasoning as wake_ask_once: a human is
# demonstrably there. Silent (and the default stands) when nobody can answer.
compact_ask_once() {
  local engine="$1" tank="$2"
  [ "$engine" = "claude" ] || return 0
  [ "$(compact_pref_get)" = "unset" ] || return 0
  [ -t 0 ] && [ -t 1 ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  if confirm "When a $engine session has sat idle ~$((COMPACT_IDLE_SECONDS / 60)) min with a big context, type /compact while its cache is still warm?"; then
    compact_pref_set on
    log_dim "  Only with an empty prompt and no turn running; once per idle stretch. Opt a tank out: clikae watch compact off $engine $tank"
  else
    compact_pref_set off
    log_dim "  Won't ask again. Turn it on later with: clikae watch compact on"
  fi
  return 0
}

# --- the readings ---------------------------------------------------------------

_compact_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0; }

_compact_min_tokens() {
  local v="${CLIKAE_COMPACT_MIN_TOKENS:-$COMPACT_MIN_TOKENS}"
  case "$v" in ''|*[!0-9]*) v="$COMPACT_MIN_TOKENS" ;; esac
  printf '%s' "$v"
}

# _compact_usage_rows -> for each assistant line on stdin that carries a real
# usage, "<context>\t<cache_creation>" where context = input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens: everything the model
# was sent on that turn, i.e. what the next turn will have to re-read.
# Synthetic lines (limit banners, API errors) carry all-zero usage and are
# skipped, so they never pass for "the context is empty".
_compact_usage_rows() {
  command -v jq >/dev/null 2>&1 || return 0
  grep -a '"type":"assistant"' | grep -a '"usage"' | jq -rR '
    (try fromjson catch null) | select(type == "object")
    | .message.usage? // empty
    | [((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)),
       (.cache_creation_input_tokens // 0)]
    | select(.[0] > 0) | @tsv' 2>/dev/null || true
}

# compact_context_tokens <transcript> -> "<context>\t<cache_creation>" of the
# LAST real turn, or nothing (return 1) when none is in the recent tail.
compact_context_tokens() {
  local f="$1" row
  [ -f "$f" ] || return 1
  row="$(transcript_tail "$f" | _compact_usage_rows | tail -n 1)"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

# compact_prompt_line_empty <captured-pane-text> -> 0 when the LAST prompt line
# on screen holds nothing typed.
#
# 🔴 This one reads the engine's UI, which the rest of the waiter refuses to do
# — there is no mechanism-level way to ask "is there a half-typed message". So
# it is written to fail SAFE: no recognisable prompt line, or anything at all
# after the prompt glyph (including a placeholder hint), means NOT empty, and
# nothing is sent. A redesign makes this feature stop acting; it can never make
# it type over someone's draft.
compact_prompt_line_empty() {
  local text="$1" line
  line="$(printf '%s\n' "$text" | grep -E '^[[:space:]]*(│[[:space:]]*)?[>❯]([[:space:]]|$)' | tail -n 1)"
  [ -n "$line" ] || return 1
  line="${line//│/}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[>❯]//; s/[[:space:]]+//g')"
  [ -z "$line" ]
}

# _compact_session_transcript <engine> <tank> <session> -> the transcript THIS
# session drives, from the id clikae stamped at launch. No id, no action: the
# cwd's "latest" could be another session's, and compacting the wrong
# conversation is not a cost saving.
_compact_session_transcript() {
  local engine="$1" tank="$2" session="$3" sid dir
  declare -F live_session_id >/dev/null 2>&1 || return 1
  declare -F profile_dir >/dev/null 2>&1 || return 1
  sid="$(live_session_id "$session" 2>/dev/null)" || return 1
  dir="$(profile_dir "$engine" "$tank" 2>/dev/null)" || return 1
  [ -d "$dir/projects" ] || return 1
  local f
  for f in "$dir"/projects/*/"$sid".jsonl; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# _compact_verify <engine> <tank> <session> -> if a send is waiting for its
# after-numbers, look past the compact boundary for the first real turn and
# write both numbers to the trace.
_compact_verify() {
  local engine="$1" tank="$2" session="$3" f="$_COMPACT_PENDING_FILE" after row
  [ -n "$f" ] && [ -f "$f" ] || return 0
  after="$(tail -c "+$((_COMPACT_PENDING_OFFSET + 1))" "$f" 2>/dev/null)"
  # Only turns AFTER the compaction count; the summary call itself is not one.
  printf '%s' "$after" | grep -aq '"compact_boundary"' || return 0
  row="$(printf '%s\n' "$after" | awk '/"compact_boundary"/ { on = 1; next } on' | _compact_usage_rows | head -n 1)"
  [ -n "$row" ] || return 0
  local ctx cre
  IFS=$'\t' read -r ctx cre <<< "$row"
  wake_trace "$engine" "$tank" "$session" compact-verified \
    "before=$_COMPACT_PENDING_BEFORE after_cache_creation=$cre after_context=$ctx"
  _COMPACT_PENDING_FILE=""
}

_compact_why() { [ -z "${CLIKAE_COMPACT_DEBUG:-}" ] || printf 'hold: %s\n' "$1"; return 1; }

# compact_tick <engine> <tank> <session> [now] -> one look. Returns 0 when it
# typed /compact this time, 1 otherwise, printing the reason it held back on
# stdout when $CLIKAE_COMPACT_DEBUG is set (tests read it; the watcher does not).
compact_tick() {
  local engine="$1" tank="$2" session="$3" now="${4:-}"
  [ -n "$now" ] || now="$(date +%s)"
  # /compact and the usage layout are Claude Code's.
  [ "$engine" = "claude" ] || { _compact_why engine; return 1; }
  compact_enabled "$engine" "$tank" || { _compact_why pref; return 1; }

  local f; f="$(_compact_session_transcript "$engine" "$tank" "$session")" || { _compact_why transcript; return 1; }
  [ "$_COMPACT_PENDING_FILE" = "$f" ] && _compact_verify "$engine" "$tank" "$session"

  local mt; mt="$(_compact_mtime "$f")"
  [ "$mt" != "$_COMPACT_SENT_MTIME" ] || { _compact_why sent-this-period; return 1; }
  [ $((now - mt)) -ge "$COMPACT_IDLE_SECONDS" ] || { _compact_why not-idle; return 1; }

  local row ctx
  row="$(compact_context_tokens "$f")" || { _compact_why no-usage; return 1; }
  ctx="${row%%$'\t'*}"
  [ "$ctx" -ge "$(_compact_min_tokens)" ] 2>/dev/null || { _compact_why small-context; return 1; }

  local target; target="$(wake_engine_target "$session")"
  wake_pane_idle "$target" "${COMPACT_SETTLE:-2}" || { _compact_why pane-busy; return 1; }
  local screen _WT_SESS _WT_PANE; _wake_targetsv "$target"
  screen="$(tmux capture-pane -p -t "$_WT_PANE" 2>/dev/null)" || { _compact_why pane-busy; return 1; }
  compact_prompt_line_empty "$screen" || { _compact_why typing; return 1; }

  wake_send "$target" "$COMPACT_COMMAND" || { _compact_why send-failed; return 1; }
  _COMPACT_SENT_MTIME="$mt"
  _COMPACT_PENDING_FILE="$f"
  _COMPACT_PENDING_OFFSET="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
  _COMPACT_PENDING_BEFORE="$ctx"
  wake_trace "$engine" "$tank" "$session" compact-sent "context=$ctx idle=$((now - mt))s"
  return 0
}

# compact_trace_recent <engine> <tank> [n] -> the last n compact-* trace lines
# for this tank, as they were written. Nothing (return 1) when there are none.
compact_trace_recent() {
  local f out
  f="$(wake_log_file "$1" "$2" "")"
  [ -f "$f" ] || return 1
  out="$(grep -a $'\tcompact-' "$f" 2>/dev/null | tail -n "${3:-5}")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
