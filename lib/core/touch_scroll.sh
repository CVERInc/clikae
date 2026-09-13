#!/usr/bin/env bash
# Translate a click-pair swipe. Args: release row, pane id, pane_in_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
y2=${1:-}; TS_PANE_ID=${2:-}; inmode=${3:-0}
# TS_PANE_ID is #{pane_id} from the binding (`%3`): an ID, already exact. tmux
# 3.4 rejects `=%3` (can't find pane), so the exact-target lint names this
# variable as an exception instead of the `=` prefix it wants for names.
[ -n "$TS_PANE_ID" ] || exit 0
enabled=$(tmux show-options -gqv @clikae_touch_scroll 2>/dev/null)
case "$enabled" in off|0|no|false) exit 0 ;; esac
y1=$(tmux show-options -pqv -t "$TS_PANE_ID" @clikae_touch_y 2>/dev/null)
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
  [ "$inmode" = 1 ] || tmux copy-mode -t "$TS_PANE_ID" || exit 0
  direction=scroll-down
  [ "$dy" -le 0 ] || direction=scroll-up
  tmux send-keys -t "$TS_PANE_ID" -X -N "$lines" "$direction"
elif [ "$inmode" = 1 ]; then
  tmux send-keys -t "$TS_PANE_ID" -X cancel
fi
