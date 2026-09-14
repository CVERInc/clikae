#!/usr/bin/env bash
# Translate a click-pair swipe. Args: release row, pane id, pane_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
y2=${1:-}; TS_PANE_ID=${2:-}; mode=${3:-}
# P2-1 (2026-09 R2 review). mode is #{pane_mode} — the mode NAME, not a stacked
# layer count — and this helper only ever acts in the two mode NAMES it knows
# how to talk to: '' (no mode; a live pane, the swipe-in case) and the two
# copy-key-table modes it binds, copy-mode/view-mode. Every other mode name
# (tree-mode, clock-mode, choose-mode, choose-mode-vi, ...) has no `send-keys
# -X` command table at all, so exit before making any tmux call rather than
# after one fails — see lib/core/tmux.sh's touch-scroll comment for what the
# old failure actually looked like on screen.
case "$mode" in
  ''|copy-mode|view-mode) ;;
  *) exit 0 ;;
esac
# TS_PANE_ID is #{pane_id} from the binding (`%3`): an ID, already exact. tmux
# 3.4 rejects `=%3` (can't find pane), so the exact-target lint names this
# variable as an exception instead of the `=` prefix it wants for names.
[ -n "$TS_PANE_ID" ] || exit 0

# _touch_opt <option> -> the value tmux would actually apply to this pane,
# walking the scope chain by hand. tmux's own -A only chains WITHIN one
# namespace — pane -> window -> global-window (documented: "Pane options
# inherit from window options... global set of window options") — it does not
# also fall through into session scope, which is a SEPARATE namespace ("a
# separate set of global session options"). clikae only ever writes the
# session/global-session pair (`set-option -og`), but a human may reasonably
# reach for `set -p`/`set -w` too, and P3-2 (2026-09 R1 review) showed the
# session level itself was silently unreachable: `set @clikae_touch_scroll
# off` in one session (no -g) left `show-options -gqv` still reading the
# global "on", because that call never asked the session level at all.
_touch_opt() {
  local name="$1" v
  v=$(tmux show-options -qv -p -A -t "$TS_PANE_ID" "$name" 2>/dev/null)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  v=$(tmux show-options -qv -t "$TS_PANE_ID" "$name" 2>/dev/null)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  tmux show-options -gqv -t "$TS_PANE_ID" "$name" 2>/dev/null
}

enabled=$(_touch_opt @clikae_touch_scroll)
# P3-1 (2026-09 R2 review): case-fold before matching. `Ctrl-b :` is hand-typed,
# and `OFF`/`Off`/`FALSE` used to scroll right on past this case list, silently
# — a human cannot be expected to hit the exact case an arm happened to be
# written in. bash 3.2 has no ${var,,}; `tr` is POSIX and needs no bashism.
case "$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]')" in
  off|0|no|false) exit 0 ;;
esac
y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
# 🔴 Use it once. UNSET immediately after reading, before any validation or
# branch below, so a stale @clikae_touch_y is not a bug to avoid causing but a
# value that cannot exist: an Up with no matching Down on its OWN key table
# (P1-2, 2026-09 R1 review — `copy-mode-vi` under `mode-keys vi` fell back to
# root and reused whatever a previous, unrelated Down had written) now finds
# nothing here rather than something old. `-p` matches how Down wrote it
# (`set-option -p -t = ...`); unlike the read above, this is NOT chained
# through _touch_opt — the value must be cleared at the exact scope it was
# written at, not wherever a fallback happened to find a copy.
tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null || true
# Validate before arithmetic: option values are user-editable.
case "$y1" in ''|*[!0-9]*) exit 0 ;; esac
case "$y2" in ''|*[!0-9]*) exit 0 ;; esac
dy=$((10#$y1 - 10#$y2)); distance=${dy#-}
if [ "$distance" -ge 2 ]; then
  multiplier=$(_touch_opt @clikae_touch_scroll_lines)
  case "$multiplier" in ''|*[!0-9]*) multiplier=2 ;; esac
  multiplier=$((10#$multiplier))
  [ "$multiplier" -gt 0 ] || multiplier=2
  lines=$((distance * multiplier))
  # already_in_mode: mode was narrowed to ''/copy-mode/view-mode above, so
  # non-empty here means copy-mode or view-mode — the P2-2 stacked-view-mode
  # case (a run-shell that prints output stacks its own view-mode over an
  # existing copy-mode) now arrives as mode=view-mode, still caught here, not
  # as a count that a literal `= 1` could miss.
  case "$mode" in
    '') tmux copy-mode -t "$TS_PANE_ID" 2>/dev/null || exit 0 ;;
  esac
  direction=scroll-down
  [ "$dy" -le 0 ] || direction=scroll-up
  tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" "$direction" 2>/dev/null || true
elif [ -n "$mode" ]; then
  tmux send-keys -t "$TS_PANE_ID" -X cancel 2>/dev/null || true
fi
