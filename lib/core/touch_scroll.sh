#!/usr/bin/env bash
# Translate a click-pair touch. Args: release row, pane id, pane_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
#
# ONE HANDLER, ONE DECISION TREE (#108). Two features arrive through the same
# MouseUp1Pane binding and must not be able to disagree about a single touch:
#
#   displacement (|dy| >= 2)  -> #88's copy-mode scroll         @clikae_touch_scroll
#   no displacement + zone    -> page the history one screen    @clikae_touch_pages
#   anything else             -> leave it alone (the release is already
#                                forwarded to the pane's program by the root
#                                binding, so "do nothing" IS "an ordinary click")
#
# The order is not arbitrary: a swipe is recognised first, so turning pages on
# can never swallow a scroll. A tap's zone is read from the PRESS row and the
# PRESS pane height (`@clikae_touch_y`/`@clikae_touch_h`, both written by the
# MouseDown binding), never from the release — the two must come from one
# geometry or a pane that resized mid-touch measures the band against the wrong
# height.
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

# P3-1 (2026-09 R2 review): case-fold before matching. `Ctrl-b :` is hand-typed,
# and `OFF`/`Off`/`FALSE` used to scroll right on past this case list, silently
# — a human cannot be expected to hit the exact case an arm happened to be
# written in. bash 3.2 has no ${var,,}; `tr` is POSIX and needs no bashism.
_touch_fold() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# 🔴 THE TWO GATES ARE ASYMMETRIC, AND DELIBERATELY SO. touch-scroll has
# shipped ON since #88, so anything that is not a recognised off-word leaves it
# on (an unreadable option must not silently remove a feature people already
# have). Tap-to-page (#108) ships OFF: it re-purposes a click that used to
# reach the program, so only a recognised on-word turns it on — an unreadable
# option leaves today's behaviour exactly as it is. They are also INDEPENDENT:
# `@clikae_touch_scroll off` does not disable paging, because a user who turned
# paging on asked for paging, not for swipe translation.
scroll_on=1
case "$(_touch_fold "$(_touch_opt @clikae_touch_scroll)")" in
  off|0|no|false) scroll_on=0 ;;
esac
pages_on=0
case "$(_touch_fold "$(_touch_opt @clikae_touch_pages)")" in
  on|1|yes|true) pages_on=1 ;;
esac
[ "$scroll_on" -eq 1 ] || [ "$pages_on" -eq 1 ] || exit 0

# _touch_zone <press row> <press pane height> -> top | bottom | '' (middle, or
# no usable band). Rows are 0-based from the top of the pane, the way
# `#{mouse_y}` counts them, so the top band is rows [0, N) and the bottom band
# is rows [height - N, height).
#
# 🔴 THE MIDDLE BAND MAY NEVER CLOSE. `@clikae_touch_pages_rows` is hand-typed
# and the pane can be four rows tall (a split, a phone in landscape): with
# N = 3 and height 6 the two bands would meet and there would be nowhere left
# on the pane to make an ordinary click — the one thing a touch device cannot
# work around, since it has no second button. N is clamped to (height - 1) / 2,
# which always leaves at least one middle row; below height 3 there is no room
# for bands at all and every tap stays a click.
_touch_zone() {
  local row="$1" h="$2" rows max
  case "$h" in ''|*[!0-9]*) return 0 ;; esac
  row=$((10#$row)); h=$((10#$h))
  rows=$(_touch_opt @clikae_touch_pages_rows)
  case "$rows" in ''|*[!0-9]*) rows=3 ;; esac
  rows=$((10#$rows))
  [ "$rows" -gt 0 ] || rows=3
  max=$(( (h - 1) / 2 ))
  [ "$max" -ge 1 ] || return 0
  [ "$rows" -le "$max" ] || rows=$max
  if [ "$row" -lt "$rows" ]; then
    printf 'top'
  elif [ "$row" -ge $(( h - rows )) ]; then
    printf 'bottom'
  fi
}

y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
h1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_h 2>/dev/null)
# 🔴 Use it once. UNSET immediately after reading, before any validation or
# branch below, so a stale @clikae_touch_y is not a bug to avoid causing but a
# value that cannot exist: an Up with no matching Down on its OWN key table
# (P1-2, 2026-09 R1 review — `copy-mode-vi` under `mode-keys vi` fell back to
# root and reused whatever a previous, unrelated Down had written) now finds
# nothing here rather than something old. `-p` matches how Down wrote it
# (`set-option -p -t = ...`); unlike the read above, this is NOT chained
# through _touch_opt — the value must be cleared at the exact scope it was
# written at, not wherever a fallback happened to find a copy. #108's
# @clikae_touch_h is the same value under the same rule — the two are halves of
# one geometry and are destroyed together, so a band can never be measured
# against a height from a touch that already happened.
tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null || true
tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_h 2>/dev/null || true
# Validate before arithmetic: option values are user-editable.
case "$y1" in ''|*[!0-9]*) exit 0 ;; esac
case "$y2" in ''|*[!0-9]*) exit 0 ;; esac
dy=$((10#$y1 - 10#$y2)); distance=${dy#-}
if [ "$distance" -ge 2 ]; then
  [ "$scroll_on" -eq 1 ] || exit 0
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
  exit 0
fi

# A TAP (|dy| <= 1 — #88's own threshold, kept exactly: a finger never lands
# and lifts on a perfectly identical row, and one row of slop was already the
# line between "tap" and "swipe" here).
#
# #108: the top band pages back one screen, the bottom band pages forward one
# screen and then, at the newest line, returns to the live view — the same
# "tap cancels back to live" ending #88 gives a tap anywhere in copy-mode,
# reached by the zone a thumb naturally lands on. Every other tap falls
# through to #88's behaviour below, untouched.
if [ "$pages_on" -eq 1 ]; then
  zone=$(_touch_zone "$y1" "$h1")
  case "$zone" in
    top)
      case "$mode" in
        '') tmux copy-mode -t "$TS_PANE_ID" 2>/dev/null || exit 0 ;;
      esac
      tmux send-keys -t "$TS_PANE_ID" -X page-up 2>/dev/null || true
      exit 0
      ;;
    bottom)
      # Outside copy-mode there is nothing below the live view to page into,
      # so the tap stays what it already is: a click the root binding
      # forwarded to the program before this helper ever ran. Doing nothing
      # here is the whole of "forward it unchanged".
      [ -n "$mode" ] || exit 0
      pos=$(tmux display-message -p -t "$TS_PANE_ID" '#{scroll_position}' 2>/dev/null)
      case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
      if [ "$((10#$pos))" -le 0 ]; then
        tmux send-keys -t "$TS_PANE_ID" -X cancel 2>/dev/null || true
      else
        tmux send-keys -t "$TS_PANE_ID" -X page-down 2>/dev/null || true
      fi
      exit 0
      ;;
  esac
fi

if [ "$scroll_on" -eq 1 ] && [ -n "$mode" ]; then
  tmux send-keys -t "$TS_PANE_ID" -X cancel 2>/dev/null || true
fi
