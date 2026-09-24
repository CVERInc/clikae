#!/usr/bin/env bash
# Translate a touch. Args: row, pane id, pane_mode, [phase], [column].
# Invoked by tmux run-shell / if-shell; no clikae state or engine
# initialization needed.
#
# THREE PHASES, ONE FILE. `phase` is the 4th argument and selects which event
# of a touch this call is translating:
#
#   ''    MouseUp1Pane        — the click pair (#88 swipe, #108 tap zones)
#   drag  MouseDrag1Pane      — one row of motion (#108, this file's drag phase)
#   end   MouseDragEnd1Pane   — the finger left the glass
#
# 🔴 WHY A DRAG PHASE EXISTS AT ALL. #88 hung its whole translation on
# MouseUp1Pane-with-displacement. Measured on a real iPhone (2026-09-16,
# a-Shell -> ssh -> tmux 3.4, passive event log): a TAP is `MouseDown1Pane` +
# `MouseUp1Pane` on the same row, but a FLICK or a press-and-drag is
# `MouseDown1Pane` + one `MouseDrag1Pane` per row crossed + `MouseDragEnd1Pane`
# — and NO MouseUp1Pane at all. #88's displacement branch therefore never fired
# on the device it was written for: tmux's own root `MouseDrag1Pane ->
# copy-mode -M` and `MouseDragEnd1Pane -> copy-pipe-and-cancel` won every time,
# which is why the gesture ended in "copied N chars to tmux buffer" instead of
# scrolling.
#
# 🔴 THE DRAG PHASE'S EXIT STATUS IS LOAD-BEARING. The drag/end bindings call
# this file through tmux's `if-shell` (not `run-shell`), so the exit status
# chooses between "clikae handled it" (0) and "run tmux's own stock command
# for this key" (non-zero). That is the whole of `@clikae_touch_drag off` ==
# stock tmux: not an approximation of the default, the default itself,
# including mouse drag-selection on a desktop. `_decline` is how any branch
# that does not want this gesture says so; in the '' (MouseUp) phase it is a
# plain `exit 0`, because run-shell has no branch to choose.
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
y2=${1:-}; TS_PANE_ID=${2:-}; mode=${3:-}; phase=${4:-}; mouse_x=${5:-}
# 🔴 EVERY FORMAT ARGUMENT IN THE BINDING IS QUOTED, AND THIS IS WHY. `#{pane_mode}`
# expands to the EMPTY STRING outside a mode — not to a placeholder, not to a
# space, to nothing at all. Unquoted in the binding's argument list it therefore
# does not produce an empty argument, it produces NO argument, and every
# argument after it shifts left one place: `phase` would arrive in `mode`.
# #88 could not see this (pane_mode was its LAST argument, so an empty
# expansion just left `$3` unset, which `${3:-}` already handled); the drag
# phase puts two arguments after it, so the binding quotes all five.
#
# `phase` itself is a LITERAL in the binding (`drag`, `end`), never a format,
# so it is matched exactly and never normalised: nothing here sanitises it,
# because a value that is not one of the three known words is not a typo to
# repair, it is a binding this build did not write. That matters on the hot
# path — a flick fires one of these per row crossed, and a normalising
# `printf | tr` would have cost two processes per event to protect against
# nothing.
# _decline — "clikae is not translating this gesture". In the drag/end phases
# the caller is `if-shell`, so a non-zero status is what makes tmux fall
# through to its OWN stock binding for this key; in the MouseUp phase the
# caller is `run-shell`, which has no branch, so the same word means exit 0.
_decline() {
  case "$phase" in
    drag|end) exit 1 ;;
    *) exit 0 ;;
  esac
}
case "$phase" in
  ''|drag|end) ;;
  # An unrecognised phase is a binding this build did not write. Decline as a
  # drag would, so an older/newer binding left in a live tmux server falls
  # through to stock rather than being silently eaten.
  *) exit 1 ;;
esac
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
  *) _decline ;;
esac
# TS_PANE_ID is #{pane_id} from the binding (`%3`): an ID, already exact. tmux
# 3.4 rejects `=%3` (can't find pane), so the exact-target lint names this
# variable as an exception instead of the `=` prefix it wants for names.
[ -n "$TS_PANE_ID" ] || _decline

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

# _touch_lines -> @clikae_touch_scroll_lines, validated. Shared by the MouseUp
# swipe branch and the drag phase on purpose: one gesture translated through
# two event shapes must move the history at the same speed, or the same flick
# scrolls a different distance depending on whether the terminal bothered to
# send motion.
_touch_lines() {
  local m
  m=$(_touch_opt @clikae_touch_scroll_lines)
  case "$m" in ''|*[!0-9]*) m=2 ;; esac
  m=$((10#$m))
  [ "$m" -gt 0 ] || m=2
  printf '%s' "$m"
}

# _touch_drag — one MouseDrag1Pane event: the finger is still down and has
# crossed to row $y2. Scrolls by the delta since the LAST row recorded for this
# pane, so a flick arrives as a stream of small scrolls that track the finger,
# not as one jump at the end (there is no end — see the header; a-Shell sends
# no MouseUp after a drag).
#
# Direction: the finger pulls the CONTENT with it. Moving DOWN the glass (y
# increases) drags older lines into view, which is `scroll-up` in copy-mode and
# WHEEL UP to an application — the same convention as every touch surface, and
# the opposite of the naive "y increased so scroll down".
_touch_drag() {
  local y1 dy distance multiplier lines geom alt height notches button seq i
  case "$y2" in ''|*[!0-9]*) _decline ;; esac
  case "$mouse_x" in ''|*[!0-9]*) mouse_x=0 ;; esac
  # The reference row is @clikae_touch_y — the SAME pane option MouseDown1Pane
  # already writes, read and rewritten on every motion event so it always holds
  # "where the finger was last seen". Reusing it rather than inventing a second
  # option is what makes press -> first motion produce a real delta immediately
  # instead of swallowing the first row of every gesture.
  y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
  tmux set-option -p -t "$TS_PANE_ID" @clikae_touch_y "$y2" 2>/dev/null || true
  # No reference row yet (a drag whose press this table never saw). Recording
  # $y2 is the whole of the work; report SUCCESS anyway, because declining here
  # would hand tmux's `copy-mode -M` the first event of a gesture we are about
  # to translate, and the user would get a selection started under their finger.
  case "$y1" in ''|*[!0-9]*) return 0 ;; esac
  dy=$((10#$y2 - 10#$y1))
  [ "$dy" -ne 0 ] || return 0
  distance=${dy#-}
  geom=$(tmux display-message -p -t "$TS_PANE_ID" '#{alternate_on} #{pane_height}' 2>/dev/null)
  alt=${geom%% *}; height=${geom##* }
  case "$height" in ''|*[!0-9]*) height=0 ;; esac
  # A finger cannot cross more rows than the pane has. Clamping is not
  # cosmetic: a resize, a reattach at another size, or two events coalesced
  # into one can produce a delta far larger than the gesture, and an unclamped
  # delta on the wheel path below becomes that many escape sequences typed into
  # somebody's editor.
  if [ "$height" -gt 0 ] && [ "$distance" -gt "$height" ]; then distance=$height; fi
  multiplier=$(_touch_lines)
  lines=$((distance * multiplier))
  # 🔴 THE ALTERNATE SCREEN HAS NO HISTORY TO SCROLL. Measured 2026-09-16: the
  # Claude Code pane runs with `alternate_on` 1 and `history_size` 0 — entering
  # copy-mode there shows the current screen and nothing above it, so #88's
  # translation is a no-op with a mode change attached. What the application
  # DOES respond to is a mouse wheel, which it is already asking for.
  #
  # 🔴 AND THE WHEEL IS SENT AS BYTES, NOT AS A KEY NAME. `tmux send-keys -t
  # <pane> WheelUpPane` does not deliver a wheel event; it TYPES THE WORD
  # (verified on a throwaway server with a pane running `cat -v`: the app read
  # the literal characters `WheelUpPane`). tmux's mouse key names exist for
  # bind-key, not for send-keys. The wheel has to go out as the raw SGR report
  # the terminal itself would have sent: ESC [ < Cb ; Cx ; Cy M, with Cb 64 for
  # wheel-up and 65 for wheel-down, and 1-based coordinates.
  if [ -z "$mode" ] && [ "$alt" = "1" ]; then
    notches=$((lines / 2))
    [ "$notches" -ge 1 ] || notches=1
    button=64
    [ "$dy" -gt 0 ] || button=65
    seq=$(printf '\033[<%s;%s;%sM' "$button" "$((10#$mouse_x + 1))" "$((10#$y2 + 1))")
    i=0
    while [ "$i" -lt "$notches" ]; do
      tmux send-keys -t "$TS_PANE_ID" -l "$seq" 2>/dev/null || true
      i=$((i + 1))
    done
    return 0
  fi
  case "$mode" in
    '') tmux copy-mode -t "$TS_PANE_ID" 2>/dev/null || _decline ;;
  esac
  if [ "$dy" -gt 0 ]; then
    tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" scroll-up 2>/dev/null || true
  else
    tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" scroll-down 2>/dev/null || true
  fi
}

# _touch_end — MouseDragEnd1Pane: the finger left the glass.
#
# Two jobs, and the first is the one that keeps the next gesture honest:
# destroy the recorded geometry, both halves together, exactly as the MouseUp
# path does. A row left behind here would be measured against the next touch's
# row and scroll the history by a distance no finger travelled.
#
# The second is the way back. A touch device has no scroll wheel and no End
# key; once copy-mode has been entered by a flick, the only cheap way out is
# the gesture that got there. So a drag that ends at the live bottom
# (`scroll_position` 0 — nothing left to come back from) cancels copy-mode and
# returns the pane to the live view, the same ending #88 gives a tap.
_touch_end() {
  local state pos
  tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null || true
  tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_h 2>/dev/null || true
  [ -n "$mode" ] || return 0
  state=$(tmux display-message -p -t "$TS_PANE_ID" '#{pane_in_mode} #{scroll_position}' 2>/dev/null)
  [ "${state%% *}" = "1" ] || return 0
  pos=${state##* }
  case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
  if [ "$((10#$pos))" -le 0 ]; then
    tmux send-keys -t "$TS_PANE_ID" -X cancel 2>/dev/null || true
  fi
}

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
# DRAG TRANSLATION IS ON BY DEFAULT (2026-09-25). The drag bindings take
# `MouseDrag1Pane`, whose stock meaning on a pane with no mouse-tracking
# program is mouse drag-SELECTION, and a-Shell's drag and a trackpad's drag are
# the SAME tmux events, so no runtime signal separates a finger from a
# trackpad. It first shipped OFF for that reason. Measured on an iPhone
# (a-Shell -> ssh -> tmux 3.7b), a flick sends no MouseUp at all, so with it
# off the phone could not scroll; the cockpit is phone / ssh first, and on a
# desktop the terminal's Option/Shift-drag still selects. So an unset or
# unreadable option means ON here, matching the launch default; only an
# explicit `off` (clikae touch drag off) declines to stock tmux:
#
#   clikae touch drag off     (or: tmux set -g @clikae_touch_drag off)
#
# `@clikae_touch_scroll` stays the master switch over both: turning touch
# scrolling off turns drag translation off with it, because a user who said
# "stop translating my touches" meant all of them.
# Empty (unset, or tmux unreadable) is ON; the on-words are ON; anything
# else, including a typo, declines to stock tmux, as it did before.
drag_on=0
case "$(_touch_fold "$(_touch_opt @clikae_touch_drag)")" in
  ''|on|1|yes|true) drag_on=1 ;;
esac
case "$phase" in
  drag|end)
    [ "$scroll_on" -eq 1 ] && [ "$drag_on" -eq 1 ] || _decline
    case "$phase" in
      drag) _touch_drag ;;
      *) _touch_end ;;
    esac
    exit 0
    ;;
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
  multiplier=$(_touch_lines)
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
