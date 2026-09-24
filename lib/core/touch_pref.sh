# shellcheck shell=bash
# lib/core/touch_pref.sh — the persisted answer to "should a finger drag scroll?"
# (#108, `@clikae_touch_drag`). Same primitive as warm /compact's preference
# (lib/core/compact.sh): one file, $CLIKAE_HOME/touch-drag, whose first bare
# `on` / `off` line is the answer. A missing or unanswered file means ON — the
# maintainer's ruling of 2026-09-25 (docs/DESIGN-tmux.md). Like the others this
# is what the human WANTS; the live tmux option is only its projection, written
# at every launch (tmux_spawn_session) and by `clikae touch drag on|off`.

touch_drag_pref_file() { printf '%s\n' "$CLIKAE_HOME/touch-drag"; }

# touch_drag_pref_raw -> on | off | unset (what the file literally says)
touch_drag_pref_raw() {
  local f v=""
  f="$(touch_drag_pref_file)"
  [ -f "$f" ] && v="$(grep -E '^[[:space:]]*(on|off)[[:space:]]*$' "$f" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  case "$v" in on|off) printf '%s' "$v" ;; *) printf 'unset' ;; esac
}

# touch_drag_pref_get -> on | off (absent or unreadable = on)
touch_drag_pref_get() {
  case "$(touch_drag_pref_raw)" in off) printf 'off' ;; *) printf 'on' ;; esac
}

# touch_drag_pref_set <on|off> -> persist it. Returns 1 on a bad value.
touch_drag_pref_set() {
  local val="$1" f rest=""
  case "$val" in on|off) : ;; *) return 1 ;; esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  f="$(touch_drag_pref_file)"
  [ -f "$f" ] && rest="$(grep -vE '^[[:space:]]*(on|off)[[:space:]]*$' "$f" 2>/dev/null | grep -v '^$' || true)"
  printf '%s\n' "$val${rest:+$'\n'}$rest" > "$f"
}
