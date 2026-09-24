# shellcheck shell=bash
# lib/commands/touch.sh — `clikae touch`: touch gestures inside tmux (#108).
#
#   clikae touch                    same as `clikae touch drag status`
#   clikae touch drag [status]      the saved preference and, if a tmux server
#                                   is up, the value it is running with
#   clikae touch drag on | off      save it AND apply it to the running server
#
# Drag-to-scroll is ON by default: a finger flick scrolls instead of starting
# tmux's drag-selection. `off` gives the stock drag-selection back (desktop
# trackpads); the terminal's own Option/Shift-drag selects either way.

_touch_live_drag() {
  tmux_server_running || return 1
  local v; v="$(tmux show-options -gqv @clikae_touch_drag 2>/dev/null)"
  printf '%s' "${v:-unset}"
}

_touch_drag_status() {
  local raw pref live
  raw="$(touch_drag_pref_raw)"; pref="$(touch_drag_pref_get)"
  if [ "$raw" = "unset" ]; then
    printf 'touch drag: %s (default)\n' "$pref"
  else
    printf 'touch drag: %s\n' "$pref"
  fi
  if live="$(_touch_live_drag)"; then
    printf '  running tmux server: %s\n' "$live"
  else
    printf '  running tmux server: none\n'
  fi
}

cmd_touch() {
  local what="${1:-drag}" verb="${2:-status}"
  case "$what" in
    drag) : ;;
    status) verb=status ;;
    -h|--help) printf 'usage: clikae touch drag [status|on|off]\n'; return 0 ;;
    *) log_err "Unknown: clikae touch $what  (usage: clikae touch drag [status|on|off])"; return 1 ;;
  esac
  case "$verb" in
    status) _touch_drag_status ;;
    on|off)
      touch_drag_pref_set "$verb" || { log_err "Could not write $(touch_drag_pref_file)"; return 1; }
      if tmux_server_running; then
        tmux set-option -g @clikae_touch_drag "$verb" 2>/dev/null \
          || { log_err "Saved, but the running tmux server refused the option"; return 1; }
        printf 'touch drag: %s (saved; applied to the running tmux server)\n' "$verb"
      else
        printf 'touch drag: %s (saved; applies at the next launch)\n' "$verb"
      fi
      ;;
    *) log_err "Unknown value: $verb  (usage: clikae touch drag [status|on|off])"; return 1 ;;
  esac
}
