#!/usr/bin/env bash
# Translate a click-pair swipe. Args: release row, pane id, pane_in_mode.
# Invoked by tmux run-shell; no clikae state or engine initialization needed.
y2=${1:-}; pane=${2:-}; inmode=${3:-0}
[ -n "$pane" ] || exit 0
enabled=$(tmux show-options -gqv @clikae_touch_scroll 2>/dev/null)
case "$enabled" in off|0|no|false) exit 0 ;; esac
y1=$(tmux show-options -pqv -t "$pane" @clikae_touch_y 2>/dev/null)
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
  [ "$inmode" = 1 ] || tmux copy-mode -t "$pane" || exit 0
  direction=scroll-down
  [ "$dy" -le 0 ] || direction=scroll-up
  tmux send-keys -t "$pane" -X -N "$lines" "$direction"
elif [ "$inmode" = 1 ]; then
  tmux send-keys -t "$pane" -X cancel
fi
