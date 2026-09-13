#!/usr/bin/env bash
# Translate a click-pair swipe. Args: release row, pane id, pane_in_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
y2=${1:-}; TS_PANE_ID=${2:-}; inmode=${3:-0}
case "$inmode" in ''|*[!0-9]*) inmode=0 ;; esac
# TS_PANE_ID is #{pane_id} from the binding (`%3`): an ID, already exact. tmux
# 3.4 rejects `=%3` (can't find pane), so the exact-target lint names this
# variable as an exception instead of the `=` prefix it wants for names.
[ -n "$TS_PANE_ID" ] || exit 0
enabled=$(tmux show-options -gqv @clikae_touch_scroll 2>/dev/null)
case "$enabled" in off|0|no|false) exit 0 ;; esac
y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
# 🔴 Use it once. UNSET immediately after reading, before any validation or
# branch below, so a stale @clikae_touch_y is not a bug to avoid causing but a
# value that cannot exist: an Up with no matching Down on its OWN key table
# (P1-2, 2026-09 R1 review — `copy-mode-vi` under `mode-keys vi` fell back to
# a stale value some earlier, unrelated Down had written) now finds nothing
# here rather than something old. `-p` matches how Down wrote it.
tmux set-option -pu -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null || true
# Validate before arithmetic: option values are user-editable.
case "$y1" in ''|*[!0-9]*) exit 0 ;; esac
case "$y2" in ''|*[!0-9]*) exit 0 ;; esac
dy=$((10#$y1 - 10#$y2)); distance=${dy#-}
if [ "$distance" -ge 2 ]; then
  multiplier=$(tmux show-options -gqv @clikae_touch_scroll_lines 2>/dev/null)
  case "$multiplier" in ''|*[!0-9]*) multiplier=2 ;; esac
  multiplier=$((10#$multiplier))
  [ "$multiplier" -gt 0 ] || multiplier=2
  lines=$((distance * multiplier))
  # #{pane_in_mode} is a COUNT of stacked mode layers, not a boolean: a
  # run-shell that produces output stacks its own view-mode over an existing
  # copy-mode, so a pane already in copy-mode can read inmode=2 (P2-2, 2026-09
  # R1 review, measured in choose-tree). `= 1` was false for that count and
  # re-entered copy-mode on top of itself; `-gt 0` treats any nonzero depth as
  # "already in a mode".
  [ "$inmode" -gt 0 ] || tmux copy-mode -t "$TS_PANE_ID" || exit 0
  direction=scroll-down
  [ "$dy" -le 0 ] || direction=scroll-up
  tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" "$direction"
elif [ "$inmode" -gt 0 ]; then
  tmux send-keys -t "$TS_PANE_ID" -X cancel
fi
